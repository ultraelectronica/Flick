use crate::audio::commands::AudioEvent;
use crate::audio::engine::audio_callback;
use crate::audio::engine::AudioCallbackData;
use crossbeam_channel::Sender;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};

const DSD_NATIVE_CHUNK_MS: u64 = 10;

pub struct DsdNativeBackend {
    stop: Arc<AtomicBool>,
    render_thread: Option<JoinHandle<()>>,
}

impl DsdNativeBackend {
    /// Opens native DSD output. `sample_rate` is the DSD byte rate
    /// (352 800 for DSD64, 705 600 for DSD128).
    ///
    /// Transports, in preference order: the vendor offload shim (framework
    /// DSD_NATIVE AudioTrack via `libsmartaudioservice.so` — the only route
    /// reachable on SELinux-locked DAPs), then direct ALSA ioctls on
    /// `/dev/snd/pcmC*D*p` (rooted/friendly ROMs).
    pub fn start(
        callback_data: Arc<AudioCallbackData>,
        event_tx: Sender<AudioEvent>,
        sample_rate: u32,
        channels: usize,
    ) -> Result<Self, String> {
        #[cfg(target_os = "android")]
        let bit_rate = sample_rate * 8;
        #[cfg_attr(not(target_os = "android"), allow(unused_mut))]
        let mut sas_failure: Option<String> = None;

        #[cfg(target_os = "android")]
        if channels == 2 {
            match super::dsd_sas_shim::create_dsd_track(bit_rate) {
                Ok(track) => {
                    // DSD wire silence (0x69): 0.0 fills pack to DC and crackle.
                    let flag_handle = Arc::clone(&callback_data);
                    flag_handle.set_dsd_wire_silence(true);
                    crate::dev_eprintln!(
                        "[DSD-NATIVE] SAS offload track opened: bit_rate={} Hz (wire {} Hz) — framework DSD_NATIVE AudioTrack, launching render thread",
                        bit_rate,
                        track.wire_rate(),
                    );
                    let stop = Arc::new(AtomicBool::new(false));
                    let stop_clone = Arc::clone(&stop);
                    // The track crosses into the render thread; keep a handle
                    // so a spawn failure can still release it.
                    let track_holder = Arc::new(std::sync::Mutex::new(Some(track)));
                    let holder_for_thread = Arc::clone(&track_holder);
                    let spawn_result = thread::Builder::new()
                        .name("dsd-native-render".to_string())
                        .spawn(move || {
                            if let Some(track) = holder_for_thread.lock().unwrap().take() {
                                dsd_sas_render_loop(
                                    track,
                                    callback_data,
                                    event_tx,
                                    sample_rate,
                                    channels,
                                    stop_clone,
                                );
                            }
                        });
                    let handle = match spawn_result {
                        Ok(handle) => handle,
                        Err(e) => {
                            flag_handle.set_dsd_wire_silence(false);
                            if let Some(track) = track_holder.lock().unwrap().take() {
                                track.release();
                            }
                            return Err(format!("Failed to spawn DSD render thread: {}", e));
                        }
                    };
                    super::dsd_sas_shim::set_active_transport(
                        super::dsd_sas_shim::TRANSPORT_SAS_OFFLOAD,
                    );
                    return Ok(Self {
                        stop,
                        render_thread: Some(handle),
                    });
                }
                Err(reason) => {
                    log::warn!(
                        "[DSD-NATIVE] SAS offload unavailable at bit_rate={} Hz: {}",
                        bit_rate,
                        reason
                    );
                    sas_failure = Some(reason);
                }
            }
        }

        log::info!(
            "[DSD-NATIVE] Opening ALSA direct DSD output: byte_rate={} Hz, ch={}",
            sample_rate,
            channels,
        );

        if !super::dsd_alsa_direct::dsd_alsa_open(sample_rate, channels) {
            crate::dev_eprintln!(
                "[DSD-NATIVE] ALSA DSD output unavailable at byte_rate={} ch={} — will fall back to DoP/PCM",
                sample_rate,
                channels,
            );
            let alsa_reason = format!(
                "ALSA DSD output unavailable at byte_rate={} ch={}",
                sample_rate, channels
            );
            return Err(match sas_failure {
                Some(sas) => format!("SAS offload: {}; {}", sas, alsa_reason),
                None => alsa_reason,
            });
        }

        crate::dev_eprintln!(
            "[DSD-NATIVE] ALSA direct output opened at {} Hz ch={} — AudioFlinger bypassed, launching render thread",
            sample_rate,
            channels,
        );

    let flag_handle = Arc::clone(&callback_data);
    flag_handle.set_dsd_wire_silence(true);
    let stop = Arc::new(AtomicBool::new(false));
    let stop_clone = Arc::clone(&stop);

    let handle = thread::Builder::new()
        .name("dsd-native-render".to_string())
        .spawn(move || {
            dsd_native_render_loop(callback_data, event_tx, sample_rate, channels, stop_clone);
            super::dsd_alsa_direct::dsd_alsa_close();
        })
        .map_err(|e| {
            flag_handle.set_dsd_wire_silence(false);
            format!("Failed to spawn DSD render thread: {}", e)
        })?;

        super::dsd_sas_shim::set_active_transport(super::dsd_sas_shim::TRANSPORT_ALSA_DIRECT);

        Ok(Self {
            stop,
            render_thread: Some(handle),
        })
    }

    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(handle) = self.render_thread.take() {
            let _ = handle.join();
        }
    }

    pub fn transport_name(&self) -> &'static str {
        super::dsd_sas_shim::native_transport_name()
    }
}

fn dsd_native_render_loop(
    callback_data: Arc<AudioCallbackData>,
    event_tx: Sender<AudioEvent>,
    sample_rate: u32,
    channels: usize,
    stop: Arc<AtomicBool>,
) {
    let valid_byte_rates = [352_800, 705_600, 1_411_200, 2_822_400];
    if !valid_byte_rates.contains(&sample_rate) {
        log::error!(
            "[DSD-NATIVE] Unexpected byte_rate={} — expected one of {:?}",
            sample_rate,
            valid_byte_rates,
        );
    }

    let chunk_frames = (((sample_rate as u64) * DSD_NATIVE_CHUNK_MS) / 1000).max(1) as usize;
    let chunk_samples = chunk_frames * channels;
    let mut render_buffer = vec![0.0f32; chunk_samples];
    let mut dsd_bytes = vec![0u8; chunk_samples];

    log::info!(
        "[DSD-NATIVE] ALSA render loop started: byte_rate={} Hz, ch={}, chunk={} frames ({}ms)",
        sample_rate,
        channels,
        chunk_frames,
        DSD_NATIVE_CHUNK_MS
    );

    while !stop.load(Ordering::Acquire) {
        audio_callback(&mut render_buffer, &callback_data, &event_tx);

        for (i, sample) in render_buffer.iter().enumerate() {
            dsd_bytes[i] = (sample.to_bits() & 0xFF) as u8;
        }

        let written = super::dsd_alsa_direct::dsd_alsa_write(&dsd_bytes);
        if written < 0 {
            log::error!("[DSD-NATIVE] ALSA write failed, stopping render loop");
            break;
        }
    }

    callback_data.set_dsd_wire_silence(false);
    log::info!("[DSD-NATIVE] ALSA render loop ended");
}

#[cfg(target_os = "android")]
fn dsd_sas_render_loop(
    track: super::dsd_sas_shim::SasTrack,
    callback_data: Arc<AudioCallbackData>,
    event_tx: Sender<AudioEvent>,
    byte_rate: u32,
    channels: usize,
    stop: Arc<AtomicBool>,
) {
    // Write granularity is probe-verified in create_dsd_track: the offload
    // HAL returns 0 for sub-frame-unit writes. Each f32 packs to one wire
    // byte, so chunk_samples == write_size regardless of grouping.
    let write_size = track.write_size(); // bytes per write call
    let group = super::dsd_sas_shim::wire_group_bytes(); // subslot bytes per channel
    let wire_frames = write_size / (group * 2); // stereo frames per write
    let chunk_frames = wire_frames * group; // DSD frames (bytes per channel)
    let chunk_samples = chunk_frames * channels;
    let mut render_buffer = vec![0.0f32; chunk_samples];
    let mut wire_buf = vec![0u8; write_size];
    let mut full_dump: Option<std::fs::File> = None;
    let mut total_written: usize = 0;

    log::info!(
        "[DSD-NATIVE] SAS render loop started: bit_rate={} Hz (wire {} Hz), chunk={} frames, write={} B",
        track.bit_rate(),
        track.wire_rate(),
        chunk_frames,
        write_size
    );

    // Prefill gate: pulling early injects a whole chunk of 0x69 silence
    // (audible pop on play/seek). Wait for one chunk first.
    {
        use std::time::{Duration, Instant};
        let min_level =
            chunk_samples as f32 / crate::audio::source::SOURCE_BUFFER_SIZE as f32;
        let deadline = Instant::now() + Duration::from_millis(2_000);
        while !stop.load(Ordering::Acquire) {
            let ready = callback_data
                .lock_sources_rt()
                .and_then(|sources| {
                    sources
                        .current()
                        .map(|s| s.has_enough_buffer() || s.buffer_level() >= min_level)
                });
            match ready {
                Some(true) => break,
                _ if Instant::now() >= deadline => {
                    log::warn!(
                        "[DSD-NATIVE] prefill gate timeout (level < {:.2}); proceeding",
                        min_level
                    );
                    break;
                }
                _ => std::thread::sleep(Duration::from_millis(10)),
            }
        }
    }

    // Starvation telemetry: growth mid-track = crackle signature; a one-time
    // jump at start/end is benign drain.
    let mut last_stats = callback_data.dsd_starve_stats();

    while !stop.load(Ordering::Acquire) {
        audio_callback(&mut render_buffer, &callback_data, &event_tx);

        super::dsd_sas_shim::pack_wire_frames(&render_buffer, channels, &mut wire_buf);

        // Wire capture for offline diffing against a reference decode:
        // continuous dump of the first 5 MiB of wire bytes.
        {
            use std::fs::OpenOptions;
            use std::io::Write;
            use std::path::Path;
            if total_written == 0 {
                let dir = Path::new("/storage/6438-6261/flick_dsd_dump");
                let _ = std::fs::create_dir_all(dir);
                if let Ok(f) = OpenOptions::new()
                    .create(true)
                    .write(true)
                    .truncate(true)
                    .open(dir.join("dsd_wire_full.bin"))
                {
                    full_dump = Some(f);
                }
            }
            if let Some(f) = full_dump.as_mut() {
                if total_written < (5 << 20) {
                    let cap = ((5 << 20) - total_written).min(write_size);
                    let _ = f.write_all(&wire_buf[..cap]);
                }
            }
            total_written += write_size;
        }

        let written = track.write(&wire_buf);
        if written <= 0 || written as usize != write_size {
            log::error!(
                "[DSD-NATIVE] SAS write failed ({} of {} bytes), stopping render loop",
                written,
                write_size
            );
            break;
        }

        let stats = callback_data.dsd_starve_stats();
        if stats != last_stats {
            log::warn!(
                "[DSD-NATIVE] starvation telemetry: +{} starved samples, +{} lock misses (totals {} / {})",
                stats.0 - last_stats.0,
                stats.1 - last_stats.1,
                stats.0,
                stats.1
            );
            last_stats = stats;
        }
    }

    track.release();
    callback_data.set_dsd_wire_silence(false);
    log::info!("[DSD-NATIVE] SAS render loop ended");
}

/// Direct PCM output over the raw ALSA ioctl path (same AudioFlinger
/// bypass as DSD native, but S32_LE PCM at the track's native rate).
/// For DAPs whose HAL resamples shared-mode streams (indicator stays at
/// 48 kHz while reporting the requested rate).
pub struct PcmAlsaBackend {
    stop: Arc<AtomicBool>,
    render_thread: Option<JoinHandle<()>>,
}

impl PcmAlsaBackend {
    pub fn start(
        callback_data: Arc<AudioCallbackData>,
        event_tx: Sender<AudioEvent>,
        sample_rate: u32,
        channels: usize,
    ) -> Result<Self, String> {
        log::info!(
            "[PCM-ALSA] Opening ALSA direct PCM output: rate={} Hz, ch={}",
            sample_rate,
            channels,
        );

        if let Err(e) = super::dsd_alsa_direct::pcm_alsa_open(sample_rate, channels) {
            return Err(format!("ALSA PCM output unavailable: {}", e));
        }

        crate::dev_eprintln!(
            "[PCM-ALSA] ALSA direct PCM output opened at {} Hz ch={} — AudioFlinger bypassed",
            sample_rate,
            channels,
        );

        let stop = Arc::new(AtomicBool::new(false));
        let stop_clone = Arc::clone(&stop);

        let handle = thread::Builder::new()
            .name("pcm-alsa-render".to_string())
            .spawn(move || {
                pcm_alsa_render_loop(callback_data, event_tx, sample_rate, channels, stop_clone);
                super::dsd_alsa_direct::dsd_alsa_close();
            })
            .map_err(|e| format!("Failed to spawn PCM ALSA render thread: {}", e))?;

        Ok(Self {
            stop,
            render_thread: Some(handle),
        })
    }

    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(handle) = self.render_thread.take() {
            let _ = handle.join();
        }
    }
}

const PCM_ALSA_CHUNK_MS: u64 = 10;

fn pcm_alsa_render_loop(
    callback_data: Arc<AudioCallbackData>,
    event_tx: Sender<AudioEvent>,
    sample_rate: u32,
    channels: usize,
    stop: Arc<AtomicBool>,
) {
    let chunk_frames = (((sample_rate as u64) * PCM_ALSA_CHUNK_MS) / 1000).max(1) as usize;
    let chunk_samples = chunk_frames * channels;
    let mut render_buffer = vec![0.0f32; chunk_samples];
    let mut pcm_bytes = vec![0u8; chunk_samples * 4];

    log::info!(
        "[PCM-ALSA] render loop started: rate={} Hz, ch={}, chunk={} frames ({}ms)",
        sample_rate,
        channels,
        chunk_frames,
        PCM_ALSA_CHUNK_MS
    );

    while !stop.load(Ordering::Acquire) {
        audio_callback(&mut render_buffer, &callback_data, &event_tx);

        for (i, sample) in render_buffer.iter().enumerate() {
            let clamped = sample.clamp(-1.0, 1.0);
            let value = (clamped * 2_147_483_648.0f32) as i32; // 2^31; int24 roundtrip is exact, `as` saturates +1.0
            pcm_bytes[i * 4..i * 4 + 4].copy_from_slice(&value.to_le_bytes());
        }

        let written = super::dsd_alsa_direct::dsd_alsa_write(&pcm_bytes);
        if written < 0 {
            log::error!("[PCM-ALSA] ALSA write failed, stopping render loop");
            break;
        }
    }

    log::info!("[PCM-ALSA] render loop ended");
}
