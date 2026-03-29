//! Core audio engine with cpal output and lock-free architecture.
//!
//! The engine manages the audio output stream, handles commands from Dart,
//! and coordinates decoding, resampling, and crossfading.

use crate::audio::commands::{AudioCommand, AudioEvent, PlaybackProgress, PlaybackState};
use crate::audio::crossfader::Crossfader;
use crate::audio::decoder::DecoderThread;
use crate::audio::dynamics::DynamicsChain;
use crate::audio::equalizer::Equalizer;
use crate::audio::source::{AudioSource, SourceProvider};
#[cfg(all(feature = "uac2", target_os = "android"))]
use crate::uac2::{android_direct_output_signature, create_android_usb_backend};

#[cfg(not(target_os = "android"))]
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
#[cfg(not(target_os = "android"))]
use cpal::{SampleRate, StreamConfig};
use crossbeam_channel::{bounded, Receiver, Sender};
#[cfg(target_os = "android")]
use oboe::{
    AudioApi, AudioDeviceDirection, AudioDeviceInfo, AudioDeviceType, AudioFormat,
    AudioOutputCallback, AudioOutputStreamSafe, AudioStream, AudioStreamAsync, AudioStreamBase,
    AudioStreamSafe, ContentType, DataCallbackResult, Output, PerformanceMode,
    SampleRateConversionQuality, SharingMode, Stereo, Usage,
};
use parking_lot::Mutex;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::Arc;
use std::thread;

/// Audio callback data shared between engine and audio thread.
///
/// This struct contains only lock-free or atomic data to ensure
/// the audio callback never blocks.
pub struct AudioCallbackData {
    /// Volume level (0.0 to 1.0)
    volume: std::sync::atomic::AtomicU32, // Using AtomicU32 for f32 bit pattern
    /// Playback speed (0.5 to 2.0)
    playback_speed: std::sync::atomic::AtomicU32, // Using AtomicU32 for f32 bit pattern
    /// Pause state
    paused: AtomicBool,
    /// Output channel count
    channels: usize,
    /// Crossfader state
    crossfader: Mutex<Crossfader>,
    /// Source provider (provides samples from current/next track)
    sources: Mutex<SourceProvider>,
    /// Pre-allocated mix buffer for crossfading
    mix_buffer_a: Mutex<Vec<f32>>,
    mix_buffer_b: Mutex<Vec<f32>>,
    /// Pre-allocated speed processing buffer
    speed_buffer: Mutex<Vec<f32>>,
    /// Fractional sample position for speed interpolation
    speed_frac_pos: Mutex<f64>,
    /// Graphic EQ (10 bands). try_lock in callback to avoid blocking.
    equalizer: Mutex<Equalizer>,
    /// Lightweight compressor + limiter chain.
    dynamics: Mutex<DynamicsChain>,
    /// Channel for sending finished tracks to command thread
    finished_tracks: Sender<AudioSource>,
}

impl AudioCallbackData {
    pub fn new(sample_rate: u32, channels: usize, finished_tracks: Sender<AudioSource>) -> Self {
        // Pre-allocate mix buffers (enough for ~100ms of audio)
        let buffer_size = (sample_rate as usize / 10) * channels;
        // Speed buffer needs to be larger to handle 2x speed (need 2x input for 1x output)
        let speed_buffer_size = buffer_size * 3;

        Self {
            volume: std::sync::atomic::AtomicU32::new(1.0f32.to_bits()),
            playback_speed: std::sync::atomic::AtomicU32::new(1.0f32.to_bits()),
            paused: AtomicBool::new(false),
            channels,
            crossfader: Mutex::new(Crossfader::disabled(sample_rate)),
            sources: Mutex::new(SourceProvider::new(sample_rate, channels)),
            mix_buffer_a: Mutex::new(vec![0.0; buffer_size]),
            mix_buffer_b: Mutex::new(vec![0.0; buffer_size]),
            speed_buffer: Mutex::new(vec![0.0; speed_buffer_size]),
            speed_frac_pos: Mutex::new(0.0),
            equalizer: Mutex::new(Equalizer::new()),
            dynamics: Mutex::new(DynamicsChain::new(sample_rate)),
            finished_tracks,
        }
    }

    #[inline]
    pub fn channels(&self) -> usize {
        self.channels
    }

    #[inline]
    pub fn get_volume(&self) -> f32 {
        f32::from_bits(self.volume.load(Ordering::Relaxed))
    }

    #[inline]
    pub fn set_volume(&self, volume: f32) {
        self.volume.store(volume.to_bits(), Ordering::Relaxed);
    }

    #[inline]
    pub fn get_playback_speed(&self) -> f32 {
        f32::from_bits(self.playback_speed.load(Ordering::Relaxed))
    }

    #[inline]
    pub fn set_playback_speed(&self, speed: f32) {
        self.playback_speed
            .store(speed.clamp(0.5, 2.0).to_bits(), Ordering::Relaxed);
    }

    #[inline]
    pub fn is_paused(&self) -> bool {
        self.paused.load(Ordering::Relaxed)
    }

    #[inline]
    pub fn set_paused(&self, paused: bool) {
        self.paused.store(paused, Ordering::Relaxed);
    }
}

/// Handle for controlling the audio engine from any thread.
///
/// This is the Send + Sync part that can be stored in a static.
pub struct AudioEngineHandle {
    /// Shared callback data
    callback_data: Arc<AudioCallbackData>,
    /// Command sender (to audio thread)
    command_tx: Sender<AudioCommand>,
    /// Event receiver (from audio processing)
    event_rx: Receiver<AudioEvent>,
    /// Current playback state
    state: Arc<AtomicU8>,
    /// Sample rate
    sample_rate: u32,
    /// Number of channels
    channels: usize,
    /// Output/backend signature used to determine when the engine must be recreated.
    output_signature: String,
    /// Active decoder threads (kept alive for the duration of playback)
    #[allow(dead_code)]
    decoders: Arc<Mutex<Vec<DecoderThread>>>,
    /// Shutdown flag
    shutdown: Arc<AtomicBool>,
}

// AudioEngineHandle is Send + Sync because it only contains Arc, channels, and atomics
unsafe impl Send for AudioEngineHandle {}
unsafe impl Sync for AudioEngineHandle {}

impl AudioEngineHandle {
    /// Send a command to the audio engine.
    pub fn send_command(&self, command: AudioCommand) -> Result<(), String> {
        self.command_tx
            .try_send(command)
            .map_err(|e| format!("Failed to send command: {}", e))
    }

    /// Play a track.
    pub fn play(&self, path: PathBuf) -> Result<(), String> {
        self.send_command(AudioCommand::Play { path })
    }

    /// Queue the next track for gapless playback.
    pub fn queue_next(&self, path: PathBuf) -> Result<(), String> {
        self.send_command(AudioCommand::QueueNext { path })
    }

    /// Pause playback.
    pub fn pause(&self) -> Result<(), String> {
        self.send_command(AudioCommand::Pause)
    }

    /// Resume playback.
    pub fn resume(&self) -> Result<(), String> {
        self.send_command(AudioCommand::Resume)
    }

    /// Stop playback.
    pub fn stop(&self) -> Result<(), String> {
        self.send_command(AudioCommand::Stop)
    }

    /// Seek to a position.
    pub fn seek(&self, position_secs: f64) -> Result<(), String> {
        self.send_command(AudioCommand::Seek { position_secs })
    }

    /// Set volume.
    pub fn set_volume(&self, volume: f32) -> Result<(), String> {
        self.send_command(AudioCommand::SetVolume { volume })
    }

    /// Configure crossfade.
    pub fn set_crossfade(&self, enabled: bool, duration_secs: f32) -> Result<(), String> {
        self.send_command(AudioCommand::SetCrossfade {
            enabled,
            duration_secs,
        })
    }

    /// Skip to next track with crossfade.
    pub fn skip_to_next(&self) -> Result<(), String> {
        self.send_command(AudioCommand::SkipToNext)
    }

    /// Set playback speed (0.5 to 2.0).
    pub fn set_playback_speed(&self, speed: f32) -> Result<(), String> {
        self.send_command(AudioCommand::SetPlaybackSpeed { speed })
    }

    /// Set graphic EQ: enabled and 10 band gains in dB (order matches EqualizerState.defaultGraphicFrequenciesHz).
    pub fn set_equalizer(&self, enabled: bool, gains_db: [f32; 10]) -> Result<(), String> {
        self.send_command(AudioCommand::SetEqualizer { enabled, gains_db })
    }

    /// Configure compressor settings.
    pub fn set_compressor(
        &self,
        enabled: bool,
        threshold_db: f32,
        ratio: f32,
        attack_ms: f32,
        release_ms: f32,
        makeup_gain_db: f32,
    ) -> Result<(), String> {
        self.send_command(AudioCommand::SetCompressor {
            enabled,
            threshold_db,
            ratio,
            attack_ms,
            release_ms,
            makeup_gain_db,
        })
    }

    /// Configure limiter settings.
    pub fn set_limiter(
        &self,
        enabled: bool,
        input_gain_db: f32,
        ceiling_db: f32,
        release_ms: f32,
    ) -> Result<(), String> {
        self.send_command(AudioCommand::SetLimiter {
            enabled,
            input_gain_db,
            ceiling_db,
            release_ms,
        })
    }

    /// Get the current playback speed.
    pub fn get_playback_speed(&self) -> f32 {
        self.callback_data.get_playback_speed()
    }

    /// Get the current playback state.
    pub fn state(&self) -> PlaybackState {
        match self.state.load(Ordering::Relaxed) {
            0 => PlaybackState::Idle,
            1 => PlaybackState::Playing,
            2 => PlaybackState::Paused,
            3 => PlaybackState::Buffering,
            4 => PlaybackState::Crossfading,
            5 => PlaybackState::Stopped,
            _ => PlaybackState::Idle,
        }
    }

    /// Get current progress.
    pub fn get_progress(&self) -> Option<PlaybackProgress> {
        let sources = self.callback_data.sources.lock();
        sources.current().map(|source| PlaybackProgress {
            position_secs: source.position_secs(),
            duration_secs: Some(source.info.duration_secs),
            buffer_level: source.buffer_level(),
        })
    }

    /// Get the current track path.
    pub fn get_current_path(&self) -> Option<PathBuf> {
        let sources = self.callback_data.sources.lock();
        sources.current().map(|source| source.info.path.clone())
    }

    /// Try to receive an event (non-blocking).
    pub fn try_recv_event(&self) -> Option<AudioEvent> {
        self.event_rx.try_recv().ok()
    }

    /// Get sample rate.
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// Get number of channels.
    pub fn channels(&self) -> usize {
        self.channels
    }

    /// Get the output/backend signature.
    pub fn output_signature(&self) -> &str {
        &self.output_signature
    }

    /// Shutdown the engine.
    pub fn shutdown(&self) -> Result<(), String> {
        self.shutdown.store(true, Ordering::Release);
        self.send_command(AudioCommand::Shutdown)
    }
}

#[cfg(not(target_os = "android"))]
fn device_supports_sample_rate(device: &cpal::Device, channels: u16, sample_rate: u32) -> bool {
    let Ok(configs) = device.supported_output_configs() else {
        return false;
    };

    configs.into_iter().any(|config| {
        config.channels() == channels
            && sample_rate >= config.min_sample_rate().0
            && sample_rate <= config.max_sample_rate().0
    })
}

#[cfg(not(target_os = "android"))]
pub fn desired_output_signature(preferred_sample_rate: Option<u32>) -> String {
    format!("native-shared:{}", preferred_sample_rate.unwrap_or(0))
}

/// Initialize the audio engine and return a handle.
///
/// The actual cpal stream runs in a dedicated thread.
#[cfg(not(target_os = "android"))]
pub fn create_audio_engine(
    preferred_sample_rate: Option<u32>,
) -> Result<AudioEngineHandle, String> {
    // Get the default audio device
    let host = cpal::default_host();
    let device = host
        .default_output_device()
        .ok_or("No default output device")?;

    // Get default config
    let default_config = device
        .default_output_config()
        .map_err(|e| format!("Failed to get default config: {}", e))?;

    let sample_rate = default_config.sample_rate().0;
    let channels = default_config.channels() as usize;
    let target_sample_rate = preferred_sample_rate
        .filter(|rate| device_supports_sample_rate(&device, channels as u16, *rate))
        .unwrap_or(sample_rate);

    eprintln!(
        "Audio engine opening output device '{}' at {} Hz (preferred: {:?})",
        device.name().unwrap_or_else(|_| "unknown".to_string()),
        target_sample_rate,
        preferred_sample_rate
    );

    let config = StreamConfig {
        channels: channels as u16,
        sample_rate: SampleRate(target_sample_rate),
        buffer_size: cpal::BufferSize::Default,
    };

    // Create finished tracks channel (from audio callback to command thread)
    let (finished_tx, finished_rx) = bounded::<AudioSource>(32);

    // Create shared data
    let callback_data = Arc::new(AudioCallbackData::new(
        target_sample_rate,
        channels,
        finished_tx,
    ));
    let callback_data_clone = Arc::clone(&callback_data);

    // Create event channel
    let (event_tx, event_rx) = bounded::<AudioEvent>(256);
    let event_tx_clone = event_tx.clone();

    // Create command channel
    let (command_tx, command_rx) = bounded::<AudioCommand>(64);

    // State
    let state = Arc::new(AtomicU8::new(PlaybackState::Idle as u8));
    let state_clone = Arc::clone(&state);

    // Decoders
    let decoders = Arc::new(Mutex::new(Vec::<DecoderThread>::new()));
    let decoders_clone = Arc::clone(&decoders);

    // Shutdown flag
    let shutdown = Arc::new(AtomicBool::new(false));
    let shutdown_clone = Arc::clone(&shutdown);

    // Callback data for command thread
    let callback_data_for_thread = Arc::clone(&callback_data);

    // Spawn the audio thread (which owns the cpal stream)
    thread::Builder::new()
        .name("audio-engine".to_string())
        .spawn(move || {
            // Build the stream in this thread
            let stream = match device.build_output_stream(
                &config,
                move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                    audio_callback(data, &callback_data_clone, &event_tx_clone);
                },
                |err| {
                    eprintln!("Audio stream error: {}", err);
                },
                None,
            ) {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("Failed to build audio stream: {}", e);
                    return;
                }
            };

            // Start the stream
            if let Err(e) = stream.play() {
                eprintln!("Failed to start audio stream: {}", e);
                return;
            }

            // Run command processing loop
            command_processing_loop(
                command_rx,
                finished_rx,
                event_tx,
                callback_data_for_thread,
                state_clone,
                decoders_clone,
                target_sample_rate,
                shutdown_clone,
            );

            // Stream will be dropped here when the loop exits
        })
        .map_err(|e| format!("Failed to spawn audio thread: {}", e))?;

    Ok(AudioEngineHandle {
        callback_data,
        command_tx,
        event_rx,
        state,
        sample_rate: target_sample_rate,
        channels,
        output_signature: desired_output_signature(Some(target_sample_rate)),
        decoders,
        shutdown,
    })
}

#[cfg(target_os = "android")]
const ANDROID_DIRECT_CHANNELS: usize = 2;
#[cfg(target_os = "android")]
const ANDROID_DIRECT_SCRATCH_SAMPLES: usize = 32_768;

#[cfg(target_os = "android")]
pub fn desired_output_signature(preferred_sample_rate: Option<u32>) -> String {
    #[cfg(feature = "uac2")]
    if let Some(signature) = android_direct_output_signature(preferred_sample_rate) {
        return signature;
    }

    format!("android-shared:{}", preferred_sample_rate.unwrap_or(48_000))
}

#[cfg(target_os = "android")]
fn parse_android_output_channels(output_signature: &str) -> Option<usize> {
    let mut parts = output_signature.split(':');
    let backend = parts.next()?;
    if backend != "android-uac2" {
        return None;
    }

    // Signature format: android-uac2:<fd>:<sample_rate>:<bit_depth>:<channels>:<device_name>
    parts.next()?;
    parts.next()?;
    parts.next()?;
    parts.next()?.parse::<usize>().ok()
}

#[cfg(target_os = "android")]
pub fn create_audio_engine(
    preferred_sample_rate: Option<u32>,
) -> Result<AudioEngineHandle, String> {
    let target_sample_rate = preferred_sample_rate.unwrap_or(48_000);
    let output_signature = desired_output_signature(Some(target_sample_rate));
    let channels =
        parse_android_output_channels(&output_signature).unwrap_or(ANDROID_DIRECT_CHANNELS);

    // Create finished tracks channel (from audio callback to command thread)
    let (finished_tx, finished_rx) = bounded::<AudioSource>(32);

    // Create shared data
    let callback_data = Arc::new(AudioCallbackData::new(
        target_sample_rate,
        channels,
        finished_tx,
    ));
    let callback_data_clone = Arc::clone(&callback_data);

    // Create event channel
    let (event_tx, event_rx) = bounded::<AudioEvent>(256);
    let event_tx_clone = event_tx.clone();

    // Create command channel
    let (command_tx, command_rx) = bounded::<AudioCommand>(64);

    // State
    let state = Arc::new(AtomicU8::new(PlaybackState::Idle as u8));
    let state_clone = Arc::clone(&state);

    // Decoders
    let decoders = Arc::new(Mutex::new(Vec::<DecoderThread>::new()));
    let decoders_clone = Arc::clone(&decoders);

    // Shutdown flag
    let shutdown = Arc::new(AtomicBool::new(false));
    let shutdown_clone = Arc::clone(&shutdown);

    // Callback data for command thread
    let callback_data_for_thread = Arc::clone(&callback_data);

    #[cfg(feature = "uac2")]
    let direct_usb_backend = if output_signature.starts_with("android-uac2:") {
        match create_android_usb_backend(
            Arc::clone(&callback_data_clone),
            event_tx_clone.clone(),
            target_sample_rate,
        )? {
            Some(backend) => Some(backend),
            None => {
                return Err(
                    "Android direct USB backend was requested but no matching USB DAC format is configured"
                        .to_string(),
                )
            }
        }
    } else {
        None
    };

    // Spawn the audio thread (which owns the Oboe stream)
    thread::Builder::new()
        .name("audio-engine".to_string())
        .spawn(move || {
            #[cfg(feature = "uac2")]
            let mut direct_usb_backend = direct_usb_backend;

            #[cfg(feature = "uac2")]
            if direct_usb_backend.is_some() {
                command_processing_loop(
                    command_rx,
                    finished_rx,
                    event_tx,
                    callback_data_for_thread,
                    state_clone,
                    decoders_clone,
                    target_sample_rate,
                    shutdown_clone,
                );

                if let Some(mut backend) = direct_usb_backend.take() {
                    let _ = backend.stop();
                }
                return;
            }

            let mut stream = match open_android_output_stream(
                Arc::clone(&callback_data_clone),
                event_tx_clone.clone(),
                target_sample_rate,
            ) {
                Ok(stream) => stream,
                Err(error) => {
                    eprintln!("Failed to open Android direct output stream: {}", error);
                    let _ = event_tx.try_send(AudioEvent::Error {
                        message: format!("Failed to open Android direct output stream: {}", error),
                    });
                    return;
                }
            };

            if let Err(error) = stream.start() {
                eprintln!("Failed to start Android direct output stream: {}", error);
                let _ = event_tx.try_send(AudioEvent::Error {
                    message: format!("Failed to start Android direct output stream: {}", error),
                });
                return;
            }

            command_processing_loop(
                command_rx,
                finished_rx,
                event_tx,
                callback_data_for_thread,
                state_clone,
                decoders_clone,
                target_sample_rate,
                shutdown_clone,
            );

            if let Err(error) = stream.stop() {
                eprintln!("Failed to stop Android direct output stream: {}", error);
            }
        })
        .map_err(|e| format!("Failed to spawn audio thread: {}", e))?;

    Ok(AudioEngineHandle {
        callback_data,
        command_tx,
        event_rx,
        state,
        sample_rate: target_sample_rate,
        channels,
        output_signature,
        decoders,
        shutdown,
    })
}

#[cfg(target_os = "android")]
struct AndroidOutputCallbackState {
    callback_data: Arc<AudioCallbackData>,
    event_tx: Sender<AudioEvent>,
    scratch: Vec<f32>,
}

#[cfg(target_os = "android")]
impl AndroidOutputCallbackState {
    fn new(callback_data: Arc<AudioCallbackData>, event_tx: Sender<AudioEvent>) -> Self {
        Self {
            callback_data,
            event_tx,
            scratch: vec![0.0; ANDROID_DIRECT_SCRATCH_SAMPLES],
        }
    }
}

#[cfg(target_os = "android")]
impl AudioOutputCallback for AndroidOutputCallbackState {
    type FrameType = (f32, Stereo);

    fn on_error_before_close(
        &mut self,
        audio_stream: &mut dyn AudioOutputStreamSafe,
        error: oboe::Error,
    ) {
        eprintln!(
            "Android direct output error before close: {:?} (device_id={}, sample_rate={} Hz, sharing={:?}, api={:?})",
            error,
            audio_stream.get_device_id(),
            audio_stream.get_sample_rate(),
            audio_stream.get_sharing_mode(),
            audio_stream.get_audio_api(),
        );
    }

    fn on_error_after_close(
        &mut self,
        audio_stream: &mut dyn AudioOutputStreamSafe,
        error: oboe::Error,
    ) {
        eprintln!(
            "Android direct output error after close: {:?} (device_id={}, sample_rate={} Hz, sharing={:?}, api={:?})",
            error,
            audio_stream.get_device_id(),
            audio_stream.get_sample_rate(),
            audio_stream.get_sharing_mode(),
            audio_stream.get_audio_api(),
        );
    }

    fn on_audio_ready(
        &mut self,
        _audio_stream: &mut dyn AudioOutputStreamSafe,
        audio_data: &mut [(f32, f32)],
    ) -> DataCallbackResult {
        let required_samples = audio_data.len() * ANDROID_DIRECT_CHANNELS;

        if required_samples > self.scratch.len() {
            for frame in audio_data.iter_mut() {
                *frame = (0.0, 0.0);
            }
            return DataCallbackResult::Continue;
        }

        let scratch = &mut self.scratch[..required_samples];
        audio_callback(scratch, &self.callback_data, &self.event_tx);

        for (frame_index, frame) in audio_data.iter_mut().enumerate() {
            let sample_index = frame_index * ANDROID_DIRECT_CHANNELS;
            *frame = (scratch[sample_index], scratch[sample_index + 1]);
        }

        DataCallbackResult::Continue
    }
}

#[cfg(target_os = "android")]
fn open_android_output_stream(
    callback_data: Arc<AudioCallbackData>,
    event_tx: Sender<AudioEvent>,
    target_sample_rate: u32,
) -> Result<AudioStreamAsync<Output, AndroidOutputCallbackState>, String> {
    let selected_device = select_android_output_device(target_sample_rate)?;
    let frames_per_callback = android_frames_per_callback(target_sample_rate);
    let attempts = [AudioApi::AAudio, AudioApi::Unspecified];

    let mut last_error = None;

    for audio_api in attempts {
        let builder = oboe::AudioStreamBuilder::default()
            .set_stereo()
            .set_f32()
            .set_sample_rate(target_sample_rate as i32)
            .set_frames_per_callback(frames_per_callback)
            .set_device_id(selected_device.id)
            .set_sharing_mode(SharingMode::Exclusive)
            .set_performance_mode(PerformanceMode::LowLatency)
            .set_usage(Usage::Media)
            .set_content_type(ContentType::Music)
            .set_channel_conversion_allowed(false)
            .set_format_conversion_allowed(false)
            .set_sample_rate_conversion_quality(SampleRateConversionQuality::None)
            .set_audio_api(audio_api);

        let stream = match builder
            .set_callback(AndroidOutputCallbackState::new(
                Arc::clone(&callback_data),
                event_tx.clone(),
            ))
            .open_stream()
        {
            Ok(stream) => stream,
            Err(error) => {
                last_error = Some(format!(
                    "{} open failed on '{}' (id {}, type {:?}): {}",
                    audio_api_label(audio_api),
                    selected_device.product_name,
                    selected_device.id,
                    selected_device.device_type,
                    error
                ));
                continue;
            }
        };

        let actual_rate = stream.get_sample_rate();
        let actual_api = stream.get_audio_api();
        let actual_sharing = stream.get_sharing_mode();
        let actual_format = stream.get_format();
        let actual_channels = stream.get_channel_count();

        eprintln!(
            "Android direct output opened '{}' (id {}, type {:?}) requested {} Hz -> actual {} Hz, api {:?}, sharing {:?}, format {:?}, channels {:?}",
            selected_device.product_name,
            selected_device.id,
            selected_device.device_type,
            target_sample_rate,
            actual_rate,
            actual_api,
            actual_sharing,
            actual_format,
            actual_channels,
        );

        if actual_rate != target_sample_rate as i32 {
            last_error = Some(format!(
                "{} opened '{}' at {} Hz instead of requested {} Hz",
                audio_api_label(audio_api),
                selected_device.product_name,
                actual_rate,
                target_sample_rate,
            ));
            continue;
        }

        return Ok(stream);
    }

    Err(last_error.unwrap_or_else(|| {
        format!(
            "No Android direct output stream could be opened for '{}' at {} Hz",
            selected_device.product_name, target_sample_rate
        )
    }))
}

#[cfg(target_os = "android")]
fn select_android_output_device(target_sample_rate: u32) -> Result<AudioDeviceInfo, String> {
    let mut devices = AudioDeviceInfo::request(AudioDeviceDirection::Output)
        .map_err(|e| format!("Failed to enumerate Android output devices: {}", e))?;

    if devices.is_empty() {
        return Err("No Android output devices found".to_string());
    }

    devices.sort_by_key(|device| {
        (
            android_output_device_priority(device.device_type),
            !android_device_supports_sample_rate(device, target_sample_rate),
            !android_device_supports_stereo(device),
            !android_device_supports_f32(device),
            device.id,
        )
    });

    for device in &devices {
        eprintln!(
            "Android output candidate '{}' (id {}, type {:?}, sample_rates={:?}, channel_counts={:?}, formats={:?})",
            device.product_name,
            device.id,
            device.device_type,
            device.sample_rates,
            device.channel_counts,
            device.formats,
        );
    }

    Ok(devices.remove(0))
}

#[cfg(target_os = "android")]
fn android_device_supports_sample_rate(device: &AudioDeviceInfo, target_sample_rate: u32) -> bool {
    device.sample_rates.is_empty() || device.sample_rates.contains(&(target_sample_rate as i32))
}

#[cfg(target_os = "android")]
fn android_device_supports_stereo(device: &AudioDeviceInfo) -> bool {
    device.channel_counts.is_empty() || device.channel_counts.iter().any(|channels| *channels >= 2)
}

#[cfg(target_os = "android")]
fn android_device_supports_f32(device: &AudioDeviceInfo) -> bool {
    device.formats.is_empty() || device.formats.contains(&AudioFormat::F32)
}

#[cfg(target_os = "android")]
fn android_output_device_priority(device_type: AudioDeviceType) -> u8 {
    match device_type {
        AudioDeviceType::UsbDevice
        | AudioDeviceType::UsbHeadset
        | AudioDeviceType::UsbAccessory
        | AudioDeviceType::Dock => 0,
        AudioDeviceType::WiredHeadphones
        | AudioDeviceType::WiredHeadset
        | AudioDeviceType::LineAnalog
        | AudioDeviceType::LineDigital
        | AudioDeviceType::Hdmi
        | AudioDeviceType::HdmiArc
        | AudioDeviceType::HdmiEarc => 1,
        AudioDeviceType::BluetoothA2DP
        | AudioDeviceType::BluetoothSCO
        | AudioDeviceType::BleBroadcast
        | AudioDeviceType::BleHeadset
        | AudioDeviceType::BleSpeaker
        | AudioDeviceType::HearingAid => 2,
        AudioDeviceType::BuiltinSpeaker
        | AudioDeviceType::BuiltinSpeakerSafe
        | AudioDeviceType::BuiltinEarpiece => 3,
        _ => 4,
    }
}

#[cfg(target_os = "android")]
fn android_frames_per_callback(target_sample_rate: u32) -> i32 {
    ((target_sample_rate / 100).clamp(96, 1024)) as i32
}

#[cfg(target_os = "android")]
fn audio_api_label(audio_api: AudioApi) -> &'static str {
    match audio_api {
        AudioApi::AAudio => "AAudio",
        AudioApi::OpenSLES => "OpenSLES",
        AudioApi::Unspecified => "Unspecified",
    }
}

/// The real-time audio callback.
///
/// This function MUST NOT:
/// - Allocate memory
/// - Block on mutexes (we use try_lock where possible)
/// - Perform I/O
#[inline]
pub(crate) fn audio_callback(
    output: &mut [f32],
    data: &AudioCallbackData,
    _event_tx: &Sender<AudioEvent>,
) {
    // Check if paused
    if data.is_paused() {
        output.fill(0.0);
        return;
    }

    // Get volume and speed
    let volume = data.get_volume();
    let speed = data.get_playback_speed();
    let channels = data.channels();

    // Try to lock sources (non-blocking)
    let mut sources = match data.sources.try_lock() {
        Some(s) => s,
        None => {
            output.fill(0.0);
            return;
        }
    };

    // Try to lock crossfader
    let mut crossfader = match data.crossfader.try_lock() {
        Some(c) => c,
        None => {
            // Couldn't get lock - just read from current source without speed processing
            let (read, old_source) = sources.read(output);

            if let Some(source) = old_source {
                let _ = data.finished_tracks.try_send(source);
            }

            if read < output.len() {
                output[read..].fill(0.0);
            }
            for sample in output.iter_mut() {
                *sample *= volume;
            }
            if let Some(mut eq) = data.equalizer.try_lock() {
                eq.process(output, channels);
            }
            if let Some(mut dynamics) = data.dynamics.try_lock() {
                dynamics.process(output, channels);
            }
            return;
        }
    };

    // Handle crossfading
    if crossfader.is_active() && sources.next_mut().is_some() {
        // Get mix buffers
        let mut buf_a = match data.mix_buffer_a.try_lock() {
            Some(b) => b,
            None => {
                output.fill(0.0);
                return;
            }
        };
        let mut buf_b = match data.mix_buffer_b.try_lock() {
            Some(b) => b,
            None => {
                output.fill(0.0);
                return;
            }
        };

        let needed = output.len();
        if buf_a.len() < needed {
            output.fill(0.0);
            return;
        }

        // Read from both sources
        let read_a = sources
            .current_mut()
            .map(|s| s.read(&mut buf_a[..needed]))
            .unwrap_or(0);
        let read_b = sources
            .next_mut()
            .map(|s| s.read(&mut buf_b[..needed]))
            .unwrap_or(0);

        if read_a < needed {
            buf_a[read_a..needed].fill(0.0);
        }
        if read_b < needed {
            buf_b[read_b..needed].fill(0.0);
        }

        // Mix with crossfade
        let _ = crossfader.mix(&buf_a[..needed], &buf_b[..needed], output, channels);

        if !crossfader.is_active() {
            drop(crossfader);
            if let Some(source) = sources.advance_to_next() {
                let _ = data.finished_tracks.try_send(source);
            }
        }
    } else {
        // Normal playback - apply speed processing if needed
        if (speed - 1.0).abs() < 0.001 {
            // Speed is 1.0 - direct read
            let (read, old_source) = sources.read(output);

            if let Some(source) = old_source {
                let _ = data.finished_tracks.try_send(source);
            }

            if read < output.len() {
                output[read..].fill(0.0);
            }
        } else {
            // Speed processing with linear interpolation
            let mut speed_buf = match data.speed_buffer.try_lock() {
                Some(b) => b,
                None => {
                    output.fill(0.0);
                    return;
                }
            };
            let mut frac_pos = match data.speed_frac_pos.try_lock() {
                Some(p) => p,
                None => {
                    output.fill(0.0);
                    return;
                }
            };

            let output_frames = output.len() / channels;
            // Calculate how many input samples we need
            let input_samples_needed =
                ((output_frames as f64 * speed as f64) + 2.0) as usize * channels;

            if speed_buf.len() < input_samples_needed {
                output.fill(0.0);
                return;
            }

            // Read source samples
            let (read, old_source) = sources.read(&mut speed_buf[..input_samples_needed]);

            if let Some(source) = old_source {
                let _ = data.finished_tracks.try_send(source);
            }

            if read < channels {
                output.fill(0.0);
                return;
            }

            let input_frames = read / channels;

            // Linear interpolation for speed change
            for out_frame in 0..output_frames {
                let in_pos = *frac_pos;
                let in_frame = in_pos as usize;
                let frac = (in_pos - in_frame as f64) as f32;

                if in_frame + 1 >= input_frames {
                    // Not enough input - fill with silence
                    for ch in 0..channels {
                        output[out_frame * channels + ch] = 0.0;
                    }
                } else {
                    // Linear interpolation between frames
                    for ch in 0..channels {
                        let s0 = speed_buf[in_frame * channels + ch];
                        let s1 = speed_buf[(in_frame + 1) * channels + ch];
                        output[out_frame * channels + ch] = s0 + (s1 - s0) * frac;
                    }
                }

                *frac_pos += speed as f64;
            }

            // Keep fractional part for next callback
            let consumed_frames = (*frac_pos) as usize;
            *frac_pos -= consumed_frames as f64;
        }
    }

    // Apply volume
    for sample in output.iter_mut() {
        *sample *= volume;
    }
    if let Some(mut eq) = data.equalizer.try_lock() {
        eq.process(output, channels);
    }
    if let Some(mut dynamics) = data.dynamics.try_lock() {
        dynamics.process(output, channels);
    }
}

/// Command processing loop running in the audio thread.
fn command_processing_loop(
    command_rx: Receiver<AudioCommand>,
    finished_rx: Receiver<AudioSource>,
    event_tx: Sender<AudioEvent>,
    callback_data: Arc<AudioCallbackData>,
    state: Arc<AtomicU8>,
    decoders: Arc<Mutex<Vec<DecoderThread>>>,
    sample_rate: u32,
    shutdown: Arc<AtomicBool>,
) {
    loop {
        // Check shutdown flag
        if shutdown.load(Ordering::Acquire) {
            break;
        }

        // Check for finished tracks
        while let Ok(source) = finished_rx.try_recv() {
            let path = source.info.path.to_string_lossy().to_string();
            let _ = event_tx.try_send(AudioEvent::TrackEnded { path });
        }

        match command_rx.recv_timeout(std::time::Duration::from_millis(50)) {
            Ok(command) => {
                match command {
                    AudioCommand::Play { path } => {
                        handle_play(
                            path,
                            &callback_data,
                            &state,
                            &decoders,
                            &event_tx,
                            sample_rate,
                        );
                    }
                    AudioCommand::QueueNext { path } => {
                        handle_queue_next(path, &callback_data, &decoders, &event_tx, sample_rate);
                    }
                    AudioCommand::Pause => {
                        callback_data.set_paused(true);
                        state.store(PlaybackState::Paused as u8, Ordering::Relaxed);
                        let _ = event_tx.try_send(AudioEvent::StateChanged(PlaybackState::Paused));
                    }
                    AudioCommand::Resume => {
                        callback_data.set_paused(false);
                        state.store(PlaybackState::Playing as u8, Ordering::Relaxed);
                        let _ = event_tx.try_send(AudioEvent::StateChanged(PlaybackState::Playing));
                    }
                    AudioCommand::Stop => {
                        callback_data.sources.lock().stop();
                        callback_data.crossfader.lock().reset();
                        state.store(PlaybackState::Stopped as u8, Ordering::Relaxed);
                        let _ = event_tx.try_send(AudioEvent::StateChanged(PlaybackState::Stopped));
                    }
                    AudioCommand::Seek { position_secs } => {
                        handle_seek(
                            position_secs,
                            &callback_data,
                            &state,
                            &decoders,
                            &event_tx,
                            sample_rate,
                        );
                    }
                    AudioCommand::SetVolume { volume } => {
                        callback_data.set_volume(volume.clamp(0.0, 1.0));
                    }
                    AudioCommand::SetCrossfade {
                        enabled,
                        duration_secs,
                    } => {
                        let mut crossfader = callback_data.crossfader.lock();
                        crossfader.set_enabled(enabled);
                        crossfader.set_duration(duration_secs);
                    }
                    AudioCommand::SetPlaybackSpeed { speed } => {
                        callback_data.set_playback_speed(speed);
                        *callback_data.speed_frac_pos.lock() = 0.0;
                    }
                    AudioCommand::SetEqualizer { enabled, gains_db } => {
                        if let Some(mut eq) = callback_data.equalizer.try_lock() {
                            eq.set(enabled, &gains_db, sample_rate);
                        }
                    }
                    AudioCommand::SetCompressor {
                        enabled,
                        threshold_db,
                        ratio,
                        attack_ms,
                        release_ms,
                        makeup_gain_db,
                    } => {
                        callback_data.dynamics.lock().set_compressor(
                            enabled,
                            threshold_db,
                            ratio,
                            attack_ms,
                            release_ms,
                            makeup_gain_db,
                        );
                    }
                    AudioCommand::SetLimiter {
                        enabled,
                        input_gain_db,
                        ceiling_db,
                        release_ms,
                    } => {
                        callback_data.dynamics.lock().set_limiter(
                            enabled,
                            input_gain_db,
                            ceiling_db,
                            release_ms,
                        );
                    }
                    AudioCommand::CrossfadeToNext | AudioCommand::SkipToNext => {
                        handle_skip_to_next(&callback_data, &state, &event_tx);
                    }
                    AudioCommand::Shutdown => {
                        // Stop everything and exit
                        callback_data.sources.lock().stop();
                        for decoder in decoders.lock().drain(..) {
                            decoder.stop();
                        }
                        break;
                    }
                }
            }
            Err(crossbeam_channel::RecvTimeoutError::Timeout) => {
                // No command - continue loop
            }
            Err(crossbeam_channel::RecvTimeoutError::Disconnected) => {
                // Channel closed - exit
                break;
            }
        }

        // Clean up finished decoders
        decoders.lock().retain(|d| d.is_running());
    }
}

fn handle_play(
    path: PathBuf,
    callback_data: &AudioCallbackData,
    state: &Arc<AtomicU8>,
    decoders: &Arc<Mutex<Vec<DecoderThread>>>,
    event_tx: &Sender<AudioEvent>,
    sample_rate: u32,
) {
    // Set buffering state
    state.store(PlaybackState::Buffering as u8, Ordering::Relaxed);
    let _ = event_tx.try_send(AudioEvent::StateChanged(PlaybackState::Buffering));

    // Stop current playback
    callback_data.sources.lock().stop();
    callback_data.crossfader.lock().reset();

    // Spawn decoder
    match DecoderThread::spawn(path.clone(), sample_rate) {
        Ok((mut source, decoder_thread)) => {
            // Wait for initial buffering
            let mut attempts = 0;
            while !source.has_enough_buffer() && attempts < 100 {
                std::thread::sleep(std::time::Duration::from_millis(10));
                attempts += 1;
            }

            source.set_ready();
            source.set_playing();

            // Set the source
            callback_data.sources.lock().set_current(source);
            callback_data.set_paused(false);

            // Store decoder
            decoders.lock().push(decoder_thread);

            // Update state
            state.store(PlaybackState::Playing as u8, Ordering::Relaxed);
            let _ = event_tx.try_send(AudioEvent::StateChanged(PlaybackState::Playing));
        }
        Err(e) => {
            let _ = event_tx.try_send(AudioEvent::Error {
                message: format!("Failed to decode {}: {}", path.display(), e),
            });
            state.store(PlaybackState::Idle as u8, Ordering::Relaxed);
        }
    }
}

fn handle_queue_next(
    path: PathBuf,
    callback_data: &AudioCallbackData,
    decoders: &Arc<Mutex<Vec<DecoderThread>>>,
    event_tx: &Sender<AudioEvent>,
    sample_rate: u32,
) {
    // Spawn decoder for next track
    match DecoderThread::spawn(path.clone(), sample_rate) {
        Ok((mut source, decoder_thread)) => {
            // Wait for initial buffering
            let mut attempts = 0;
            while !source.has_enough_buffer() && attempts < 100 {
                std::thread::sleep(std::time::Duration::from_millis(10));
                attempts += 1;
            }

            source.set_ready();

            // Queue the source
            callback_data.sources.lock().queue_next(source);

            // Store decoder
            decoders.lock().push(decoder_thread);

            let _ = event_tx.try_send(AudioEvent::NextTrackReady {
                path: path.to_string_lossy().to_string(),
            });
        }
        Err(e) => {
            let _ = event_tx.try_send(AudioEvent::Error {
                message: format!("Failed to decode next track {}: {}", path.display(), e),
            });
        }
    }
}

fn handle_skip_to_next(
    callback_data: &AudioCallbackData,
    state: &Arc<AtomicU8>,
    event_tx: &Sender<AudioEvent>,
) {
    let mut sources = callback_data.sources.lock();
    let mut crossfader = callback_data.crossfader.lock();

    if sources.has_next() {
        if crossfader.is_enabled() {
            // Start crossfade
            crossfader.start();
            state.store(PlaybackState::Crossfading as u8, Ordering::Relaxed);
            let _ = event_tx.try_send(AudioEvent::StateChanged(PlaybackState::Crossfading));
        } else {
            // Immediate transition
            sources.advance_to_next();
            state.store(PlaybackState::Playing as u8, Ordering::Relaxed);
        }
    }
}

fn handle_seek(
    position_secs: f64,
    callback_data: &AudioCallbackData,
    state: &Arc<AtomicU8>,
    decoders: &Arc<Mutex<Vec<DecoderThread>>>,
    event_tx: &Sender<AudioEvent>,
    sample_rate: u32,
) {
    let target_secs = position_secs.max(0.0);

    let current_path = {
        let sources = callback_data.sources.lock();
        sources.current().map(|s| s.info.path.clone())
    };

    let Some(path) = current_path else {
        let _ = event_tx.try_send(AudioEvent::Error {
            message: "Seek failed: no track loaded".to_string(),
        });
        return;
    };

    let was_paused = callback_data.is_paused();

    state.store(PlaybackState::Buffering as u8, Ordering::Relaxed);
    let _ = event_tx.try_send(AudioEvent::StateChanged(PlaybackState::Buffering));

    callback_data.sources.lock().stop();
    callback_data.crossfader.lock().reset();
    *callback_data.speed_frac_pos.lock() = 0.0;

    {
        let mut active_decoders = decoders.lock();
        for decoder in active_decoders.drain(..) {
            decoder.stop();
        }
    }

    match DecoderThread::spawn_with_seek(path.clone(), sample_rate, Some(target_secs)) {
        Ok((mut source, decoder_thread)) => {
            let mut attempts = 0;
            while !source.has_enough_buffer() && attempts < 100 {
                std::thread::sleep(std::time::Duration::from_millis(10));
                attempts += 1;
            }

            source.set_ready();
            if !was_paused {
                source.set_playing();
            }

            callback_data.sources.lock().set_current(source);
            callback_data.set_paused(was_paused);
            decoders.lock().push(decoder_thread);

            let next_state = if was_paused {
                PlaybackState::Paused
            } else {
                PlaybackState::Playing
            };
            state.store(next_state as u8, Ordering::Relaxed);
            let _ = event_tx.try_send(AudioEvent::StateChanged(next_state));
        }
        Err(e) => {
            let _ = event_tx.try_send(AudioEvent::Error {
                message: format!(
                    "Seek failed for {} to {:.2}s: {}",
                    path.display(),
                    target_secs,
                    e
                ),
            });
            state.store(PlaybackState::Idle as u8, Ordering::Relaxed);
            let _ = event_tx.try_send(AudioEvent::StateChanged(PlaybackState::Idle));
        }
    }
}
