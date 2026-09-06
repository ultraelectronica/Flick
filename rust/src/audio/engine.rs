//! Core audio engine with cpal output and lock-free architecture.
//!
//! The engine manages the audio output stream, handles commands from Dart,
//! and coordinates decoding, resampling, and crossfading.

use crate::dev_eprintln;

use crate::audio::commands::{AudioCommand, AudioEvent, PlaybackProgress, PlaybackState};
use crate::audio::convolver::Convolver;
use crate::audio::crossfader::Crossfader;
use crate::audio::decoder::{probe_http, DecoderThread};
use crate::audio::decoder_handle::{detect_file_type, DecoderHandle, FileType};
#[cfg(target_os = "android")]
use crate::audio::device::current_device_profile;
use crate::audio::dsd_engine::DsdDecoderThread;
use crate::audio::dynamics::DynamicsChain;
use crate::audio::crossfeed::{Crossfeed, CrossfeedLevel};
use crate::audio::equalizer::{EqBandSpec, Equalizer};
use crate::audio::fx::SpatialFx;
use crate::audio::pitch_shifter::PitchShifter;
use crate::audio::source::{AudioSource, SourceProvider};
use crate::audio::strategy::OutputStrategy;
#[cfg(target_os = "android")]
use crate::audio::strategy::{select_strategy_excluded, DeviceCaps, TrackInfo};
#[cfg(target_os = "android")]
use crate::audio::verifier::OutputVerification;
use crate::audio::wavpack_thread::WavpackDecoderThread;
#[cfg(all(feature = "uac2", target_os = "android"))]
use crate::uac2::{
    android_direct_debug_state, android_direct_output_signature, create_android_usb_backend,
    validate_android_direct_request,
};

#[cfg(not(target_os = "android"))]
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
#[cfg(not(target_os = "android"))]
use cpal::{SampleRate, StreamConfig};
use crossbeam_channel::{bounded, Receiver, Sender};
#[cfg(target_os = "android")]
use oboe::{
    AudioApi, AudioDeviceDirection, AudioDeviceInfo, AudioDeviceType, AudioFormat,
    AudioOutputCallback, AudioOutputStreamSafe, AudioStream, AudioStreamAsync, AudioStreamBase,
    AudioStreamSafe, ChannelCount, ContentType, DataCallbackResult, Output, PerformanceMode,
    SampleRateConversionQuality, SharingMode, Stereo, Usage,
};
use parking_lot::Mutex;
use serde::Serialize;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicU8, Ordering};
use std::sync::Arc;
use std::thread;

pub static XRUN_COUNT: AtomicU64 = AtomicU64::new(0);

/// Global 432 Hz tuning override. When enabled the engine leaves bit-perfect
/// passthrough and runs the DSP path at 432/440 speed. This is experimental
/// and intentionally breaks strict bit-perfect delivery.
pub static TUNING_432HZ_ENABLED: AtomicBool = AtomicBool::new(false);
const TUNING_432HZ_RATIO: f32 = 432.0 / 440.0;

/// Maximum linear volume slider value. Extended-volume boost (200 %) is
/// applied above 1.0; gain scales linearly to 2.0 (+6 dB) at the cap.
pub const MAX_VOLUME: f32 = 2.0;

/// User-facing preference for the Android low-level audio API that Oboe wraps.
/// `Auto` lets Oboe choose (AAudio then OpenSL ES); the explicit variants force
/// that API first, with `Unspecified` as a safety net so audio still plays if the
/// chosen API is unavailable (e.g. AAudio on API 26). Bluetooth always defers to
/// Oboe's default since exclusive mode is wrong for the mixer path.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AudioApiPreference {
    Auto,
    AAudio,
    OpenSLES,
}

impl AudioApiPreference {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::AAudio => "aaudio",
            Self::OpenSLES => "opensles",
        }
    }

    pub fn from_str(value: &str) -> Self {
        match value {
            "aaudio" => Self::AAudio,
            "opensles" => Self::OpenSLES,
            _ => Self::Auto,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct AudioOutputRuntimeState {
    pub strategy: String,
    pub requested_sample_rate: u32,
    pub actual_sample_rate: u32,
    pub resampler_active: bool,
    pub passthrough_allowed: bool,
    pub verification_reason: Option<String>,
    pub direct_usb_active: bool,
    pub direct_usb_verified: bool,
    pub dsd_source_rate: Option<u32>,
    pub dsd_effective_mode: Option<String>,
    pub dsd_wire_rate: Option<u32>,
    pub dsd_transport: Option<String>,
    pub active_audio_api: Option<String>,
}

/// Pipeline mode: set once at engine creation time, never toggled at runtime.
///
/// Like USB direct, when the engine runs in Passthrough mode the audio
/// callback skips ALL DSP (EQ, dynamics, speed, crossfade). The only
/// processing applied is gain — which is a no-op when DAC hardware
/// volume is available.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(u8)]
pub(crate) enum PipelineMode {
    Passthrough = 0,
    Dsp = 1,
    Dop = 2,
}

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
    /// Pipeline mode (Passthrough or Dsp) — immutable after creation.
    /// Stored as AtomicU8 for lock-free reads from the audio callback.
    pipeline_mode: AtomicU8,
    /// Base pipeline mode saved before Dop override. Restored when DoP track ends.
    base_pipeline_mode: AtomicU8,
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
    /// Creative spatial/time FX.
    fx: Mutex<SpatialFx>,
    /// BS2B (Bauer stereophonic-to-binaural) crossfeed. Reduces headphone ear
    /// fatigue by blending a low-passed opposite-channel signal into each
    /// channel. Runs in Dsp mode like the other FX.
    crossfeed: Mutex<Crossfeed>,
    /// Impulse-response convolver (room reverb, crossfeed, cabinet/correction
    /// IRs). Loaded off-callback; runs only in Dsp mode like the other FX.
    convolver: Mutex<Convolver>,
    /// Lightweight compressor + limiter chain.
    dynamics: Mutex<DynamicsChain>,
    /// Pitch shifter (semitone offset, tempo preserved). Runs at the head of
    /// the DSP chain. try_lock in callback to avoid blocking.
    pitch_shifter: Mutex<PitchShifter>,
    /// Lock-free mirror of `pitch_shifter.semitones() != 0`. Forces the
    /// callback out of passthrough so shifting runs even on a verified
    /// bit-perfect output (same trick as crossfade_forces_dsp).
    pitch_shift_forces_dsp: AtomicBool,
    /// Lock-free mirror of an active EQ. Forces the callback out of
    /// passthrough so the biquads run even on a verified bit-perfect USB
    /// output (same trick as crossfade/pitch_shift_forces_dsp). Without
    /// this, EQ is silently dropped on bit-perfect pipelines.
    eq_forces_dsp: AtomicBool,
    /// Lock-free mirror of an active crossfeed. Forces the callback out of
    /// passthrough so the BS2B filters run even on a verified bit-perfect USB
    /// output (same trick as EQ).
    crossfeed_forces_dsp: AtomicBool,
    /// Effective ReplayGain for the current track (dB, f32 bits). New sources
    /// are stamped with this value at spawn; [AudioCommand::SetReplayGain]
    /// updates it live. ReplayGain != 0 dB needs the DSP path, so this also
    /// mirrors into [replaygain_forces_dsp].
    replaygain_db: AtomicU32,
    /// Lock-free mirror of a non-neutral ReplayGain. Forces the callback out
    /// of passthrough so per-source gain runs even on bit-perfect outputs.
    replaygain_forces_dsp: AtomicBool,
    /// Channel for sending finished tracks to command thread
    finished_tracks: Sender<AudioSource>,
    /// Experimental 432 Hz tuning override. When enabled the callback leaves
    /// passthrough and uses the DSP path at 432/440 speed.
    tuning_432hz_enabled: AtomicBool,
    /// Set when crossfade is enabled. Forces the callback out of passthrough so
    /// the DSP/crossfade mix path runs — even when the engine verified a
    /// bit-perfect output (e.g. MixerBitPerfect on a phone whose speaker
    /// natively supports the track rate). Without this, crossfade is silently
    /// skipped because is_passthrough() returns true.
    crossfade_forces_dsp: AtomicBool,
    /// Lock-free mirror of `crossfader.is_active()`. The command thread polls
    /// this instead of locking the crossfader so the real-time callback's
    /// `try_lock` never collides mid-fade (a collision drops the fade gains and
    /// emits the outgoing track at full volume = audible chopping).
    crossfade_active: AtomicBool,
    /// Set by the Oboe error callback when the output stream is disconnected
    /// (audio focus loss, phone call, route change). The command loop reopens
    /// the stream so playback resumes at the interrupted position instead of
    /// jumping to another time.
    stream_needs_restart: AtomicBool,
    /// Native-DSD transport active: silence fills emit the SACD silence byte
    /// 0x69 (a 0.0 f32 packs to wire 0x00 = DC = pops).
    dsd_wire_silence: AtomicBool,
    /// DoP transport active: silence fills carry 0x05/0xFA marker framing
    /// (zero words desync the DAC's marker detector and click).
    dop_wire_silence: AtomicBool,
    /// Phase for the alternating 0x05/0xFA DoP silence marker.
    dop_marker_phase: AtomicBool,
    /// Telemetry: DSD silence samples injected due to short ring reads.
    dsd_starved_samples: AtomicU64,
    /// Telemetry: callbacks silenced by `sources` lock contention.
    dsd_lock_misses: AtomicU64,
}

impl AudioCallbackData {
    pub(crate) fn new(
        sample_rate: u32,
        channels: usize,
        finished_tracks: Sender<AudioSource>,
        pipeline_mode: PipelineMode,
    ) -> Self {
        // Pre-allocate mix buffers for 1 second of audio — large enough
        // for any platform's output callback (cpal can deliver up to 8k
        // frames; Oboe typically ~1k). The floor keeps a bogus sample rate
        // from collapsing the scratch buffers to callback-hostile sizes.
        let buffer_size = (sample_rate as usize * channels).max(8192 * channels.max(1));
        // Speed buffer needs to be larger to handle 2x speed (need 2x input for 1x output)
        let speed_buffer_size = buffer_size * 3;

        let tuning_enabled = TUNING_432HZ_ENABLED.load(Ordering::Relaxed);
        let initial_speed = if tuning_enabled {
            TUNING_432HZ_RATIO
        } else {
            1.0f32
        };

        Self {
            volume: std::sync::atomic::AtomicU32::new(1.0f32.to_bits()),
            playback_speed: std::sync::atomic::AtomicU32::new(initial_speed.to_bits()),
            paused: AtomicBool::new(false),
            pipeline_mode: AtomicU8::new(pipeline_mode as u8),
            base_pipeline_mode: AtomicU8::new(pipeline_mode as u8),
            channels,
            crossfader: Mutex::new(Crossfader::disabled(sample_rate)),
            sources: Mutex::new(SourceProvider::new(sample_rate, channels)),
            mix_buffer_a: Mutex::new(vec![0.0; buffer_size]),
            mix_buffer_b: Mutex::new(vec![0.0; buffer_size]),
            speed_buffer: Mutex::new(vec![0.0; speed_buffer_size]),
            speed_frac_pos: Mutex::new(0.0),
            equalizer: Mutex::new(Equalizer::new()),
            fx: Mutex::new(SpatialFx::new(sample_rate)),
            crossfeed: Mutex::new(Crossfeed::new(sample_rate)),
            convolver: Mutex::new(Convolver::new(sample_rate)),
            dynamics: Mutex::new(DynamicsChain::new(sample_rate)),
            pitch_shifter: Mutex::new(PitchShifter::new(sample_rate, channels)),
            pitch_shift_forces_dsp: AtomicBool::new(false),
            eq_forces_dsp: AtomicBool::new(false),
            crossfeed_forces_dsp: AtomicBool::new(false),
            replaygain_db: AtomicU32::new(0.0f32.to_bits()),
            replaygain_forces_dsp: AtomicBool::new(false),
            finished_tracks,
            tuning_432hz_enabled: AtomicBool::new(tuning_enabled),
            crossfade_forces_dsp: AtomicBool::new(false),
            crossfade_active: AtomicBool::new(false),
            stream_needs_restart: AtomicBool::new(false),
            dsd_wire_silence: AtomicBool::new(false),
            dop_wire_silence: AtomicBool::new(false),
            dop_marker_phase: AtomicBool::new(false),
            dsd_starved_samples: AtomicU64::new(0),
            dsd_lock_misses: AtomicU64::new(0),
        }
    }

    /// Managed by the DSD native backend around its render thread (see
    /// [Self::fill_silence]).
    #[inline]
    pub(crate) fn set_dsd_wire_silence(&self, enabled: bool) {
        self.dsd_wire_silence.store(enabled, Ordering::Relaxed);
    }

    /// Managed around DoP render loops (see [Self::fill_silence]).
    #[inline]
    pub(crate) fn set_dop_wire_silence(&self, enabled: bool) {
        self.dop_wire_silence.store(enabled, Ordering::Relaxed);
    }

    /// Transport-appropriate silence: DSD wire gets byte 0x69 (0.0 packs to
    /// DC and pops), DoP wire gets marker-framed words, PCM gets 0.0.
    #[inline]
    pub(crate) fn fill_silence(&self, output: &mut [f32]) {
        if self.dsd_wire_silence.load(Ordering::Relaxed) {
            output.fill(f32::from_bits(0x69));
        } else if self.dop_wire_silence.load(Ordering::Relaxed) {
            let mut marker_is_fa = self.dop_marker_phase.load(Ordering::Relaxed);
            for sample in output.iter_mut() {
                let marker = if marker_is_fa { 0xFA } else { 0x05 };
                *sample = f32::from_bits((marker as u32) << 24 | 0x69 << 16 | 0x96 << 8);
                marker_is_fa = !marker_is_fa;
            }
            self.dop_marker_phase.store(marker_is_fa, Ordering::Relaxed);
        } else {
            output.fill(0.0);
        }
    }

    /// try_lock for `sources` that yield-retries briefly — a plain miss in
    /// the RT callback would silence a whole DSD chunk = audible pop.
    pub(crate) fn lock_sources_rt(
        &self,
    ) -> Option<parking_lot::MutexGuard<'_, SourceProvider>> {
        for attempt in 0..64 {
            if let Some(guard) = self.sources.try_lock() {
                return Some(guard);
            }
            if attempt < 63 {
                std::thread::yield_now();
            }
        }
        None
    }

    /// (starved samples, lock misses) telemetry snapshot for the DSD render
    /// loop's warn-on-change logging.
    #[allow(dead_code)] // consumed by the Android-only SAS render loop
    pub(crate) fn dsd_starve_stats(&self) -> (u64, u64) {
        (
            self.dsd_starved_samples.load(Ordering::Relaxed),
            self.dsd_lock_misses.load(Ordering::Relaxed),
        )
    }

    #[inline]
    pub fn channels(&self) -> usize {
        self.channels
    }

    #[inline]
    pub fn get_volume(&self) -> f32 {
        f32::from_bits(self.volume.load(Ordering::Relaxed))
    }

    /// Perceptual gain from linear slider value (0-1).
    /// Maps to ≈[-60 dB, 0 dB] so 50 % slider sounds like half loudness.
    #[inline]
    pub fn get_gain(&self) -> f32 {
        volume_to_gain(self.get_volume())
    }

    #[inline]
    pub fn set_volume(&self, volume: f32) {
        debug_assert!(
            (0.0..=MAX_VOLUME).contains(&volume) || volume.is_nan(),
            "Volume out of range: {volume}"
        );
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

    /// Effective ReplayGain (dB) applied to sources spawned afterwards.
    #[inline]
    pub fn get_replaygain_db(&self) -> f32 {
        f32::from_bits(self.replaygain_db.load(Ordering::Relaxed))
    }

    #[inline]
    pub fn set_replaygain_db(&self, gain_db: f32) {
        self.replaygain_db.store(gain_db.to_bits(), Ordering::Relaxed);
        self.replaygain_forces_dsp
            .store(gain_db != 0.0, Ordering::Relaxed);
    }

    /// Toggle experimental 432 Hz tuning. This switches the effective pipeline
    /// out of passthrough and pins playback speed to 432/440.
    #[inline]
    pub fn set_432hz_tuning_enabled(&self, enabled: bool) {
        self.tuning_432hz_enabled.store(enabled, Ordering::Relaxed);
        let speed = if enabled { TUNING_432HZ_RATIO } else { 1.0f32 };
        self.playback_speed
            .store(speed.to_bits(), Ordering::Relaxed);
        *self.speed_frac_pos.lock() = 0.0;
        // The crossfade mix bypasses speed resampling, so an in-progress fade
        // would emit audio at the wrong pitch under the pinned 432/440 speed.
        if enabled {
            self.crossfader.lock().reset();
            self.crossfade_active.store(false, Ordering::Relaxed);
        }
    }

    #[inline]
    pub fn is_paused(&self) -> bool {
        self.paused.load(Ordering::Relaxed)
    }

    #[inline]
    pub fn set_paused(&self, paused: bool) {
        self.paused.store(paused, Ordering::Relaxed);
    }

    /// Mark the Oboe output stream as disconnected so the command loop reopens
    /// it and resumes playback at the interrupted position.
    #[inline]
    pub fn request_stream_restart(&self) {
        self.stream_needs_restart.store(true, Ordering::Release);
    }

    #[inline]
    pub fn stream_restart_requested(&self) -> bool {
        self.stream_needs_restart.load(Ordering::Acquire)
    }

    #[inline]
    pub fn clear_stream_restart_request(&self) {
        self.stream_needs_restart.store(false, Ordering::Release);
    }

    #[inline]
    pub fn is_passthrough(&self) -> bool {
        let mode = self.pipeline_mode.load(Ordering::Relaxed);
        let tuning = self.tuning_432hz_enabled.load(Ordering::Relaxed);
        let crossfade = self.crossfade_forces_dsp.load(Ordering::Relaxed);
        let pitch = self.pitch_shift_forces_dsp.load(Ordering::Relaxed);
        let eq = self.eq_forces_dsp.load(Ordering::Relaxed);
        let crossfeed = self.crossfeed_forces_dsp.load(Ordering::Relaxed);
        let replaygain = self.replaygain_forces_dsp.load(Ordering::Relaxed);
        mode == PipelineMode::Passthrough as u8
            && !tuning
            && !crossfade
            && !pitch
            && !eq
            && !crossfeed
            && !replaygain
    }

    /// Whether crossfade may run. Crossfade requires the DSP path (not
    /// passthrough) AND must be suppressed under 432 Hz tuning, because the
    /// crossfade mix branch bypasses the speed resampler and would emit audio
    /// at the wrong pitch while the engine is pinned to 432/440.
    #[inline]
    pub fn is_crossfade_allowed(&self) -> bool {
        !self.is_passthrough() && !self.tuning_432hz_enabled.load(Ordering::Relaxed)
    }

    #[inline]
    pub fn is_dop(&self) -> bool {
        self.pipeline_mode.load(Ordering::Relaxed) == PipelineMode::Dop as u8
    }

    #[inline]
    pub(crate) fn set_pipeline_mode(&self, mode: PipelineMode) {
        self.pipeline_mode.store(mode as u8, Ordering::Relaxed);
    }

    pub fn reconfigure_sample_rate(&self, sample_rate: u32) {
        // Floor keeps a bogus rate from collapsing the scratch buffers below
        // a usable callback size (see the buffer guard in the callback).
        let buffer_size =
            ((sample_rate as usize / 10) * self.channels).max(8192 * self.channels.max(1));
        let speed_buffer_size = buffer_size * 3;

        self.crossfader.lock().rebind_sample_rate(sample_rate);
        self.crossfade_active.store(false, Ordering::Relaxed);
        *self.sources.lock() = SourceProvider::new(sample_rate, self.channels);
        *self.mix_buffer_a.lock() = vec![0.0; buffer_size];
        *self.mix_buffer_b.lock() = vec![0.0; buffer_size];
        *self.speed_buffer.lock() = vec![0.0; speed_buffer_size];
        *self.speed_frac_pos.lock() = 0.0;
        self.fx.lock().reconfigure_sample_rate(sample_rate);
        self.crossfeed.lock().rebind_sample_rate(sample_rate);
        self.convolver.lock().reconfigure_sample_rate(sample_rate);
        *self.dynamics.lock() = DynamicsChain::new(sample_rate);
        let semitones = self.pitch_shifter.lock().semitones();
        let mut shifter = PitchShifter::new(sample_rate, self.channels);
        shifter.set_semitones(semitones);
        *self.pitch_shifter.lock() = shifter;
    }
}

/// Surface an audio-thread panic as an Error event so release builds can
/// still see why commands started failing (a dead thread otherwise only
/// shows up as "sending on a disconnected channel").
fn report_thread_panic(
    event_tx: &Sender<AudioEvent>,
    result: Result<(), Box<dyn std::any::Any + Send>>,
) {
    let Err(panic) = result else { return };
    let detail = if let Some(s) = panic.downcast_ref::<String>() {
        s.clone()
    } else if let Some(s) = panic.downcast_ref::<&str>() {
        (*s).to_string()
    } else {
        "unknown panic payload".to_string()
    };
    dev_eprintln!("[ENGINE] audio command thread panicked: {}", detail);
    let _ = event_tx.try_send(AudioEvent::Error {
        message: format!("Audio engine thread crashed: {}", detail),
    });
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
    /// Runtime output state after strategy selection and verification.
    output_runtime: AudioOutputRuntimeState,
    /// The Android audio-API preference the engine was built with. Used to
    /// detect when a preference change must force a stream reopen.
    audio_api_pref: AudioApiPreference,
    /// Active decoder threads (kept alive for the duration of playback)
    #[allow(dead_code)]
    decoders: Arc<Mutex<Vec<DecoderHandle>>>,
    /// Shutdown flag
    shutdown: Arc<AtomicBool>,
    /// Audio thread handle, joined on shutdown to ensure the
    /// output stream is released before a new engine opens one.
    _audio_thread: parking_lot::Mutex<Option<std::thread::JoinHandle<()>>>,
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

    /// True while the audio command thread (owner of the command channel) is
    /// still running. If it panicked or exited, every send_command fails with
    /// "sending on a disconnected channel" forever, so the engine must be
    /// recreated.
    pub fn is_alive(&self) -> bool {
        self._audio_thread
            .lock()
            .as_ref()
            .is_some_and(|handle| !handle.is_finished())
    }

    /// Play a track.
    pub fn play(&self, path: PathBuf) -> Result<(), String> {
        self.send_command(AudioCommand::Play { path })
    }

    /// Play a track using a pre-created source and decoder thread.
    pub fn play_prepared(
        &self,
        source: AudioSource,
        decoder_handle: DecoderHandle,
    ) -> Result<(), String> {
        self.send_command(AudioCommand::PlayPrepared {
            source,
            decoder_handle,
        })
    }

    /// Queue the next track for gapless playback.
    pub fn queue_next(&self, path: PathBuf) -> Result<(), String> {
        self.send_command(AudioCommand::QueueNext { path })
    }

    /// Queue the next track using a pre-created source and decoder handle.
    pub fn queue_next_prepared(
        &self,
        source: AudioSource,
        decoder_handle: DecoderHandle,
    ) -> Result<(), String> {
        self.send_command(AudioCommand::QueueNextPrepared {
            source,
            decoder_handle,
        })
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

    /// Set the effective ReplayGain (dB) for the current track and as the
    /// default for subsequently spawned sources. 0.0 = off.
    pub fn set_replaygain(&self, gain_db: f32) -> Result<(), String> {
        self.send_command(AudioCommand::SetReplayGain { gain_db })
    }

    /// Set the spawn-time default ReplayGain (dB) without touching the
    /// currently-running source. Used when pre-queueing the next gapless
    /// track, whose gain is stamped on the newly spawned source.
    pub fn set_replaygain_default(&self, gain_db: f32) -> Result<(), String> {
        self.send_command(AudioCommand::SetReplayGainDefault { gain_db })
    }

    /// Configure crossfade.
    pub fn set_crossfade(&self, enabled: bool, duration_secs: f32) -> Result<(), String> {
        self.send_command(AudioCommand::SetCrossfade {
            enabled,
            duration_secs,
        })
    }

    /// Set the crossfade curve type.
    pub fn set_crossfade_curve(
        &self,
        curve: crate::audio::crossfader::CrossfadeCurve,
    ) -> Result<(), String> {
        self.send_command(AudioCommand::SetCrossfadeCurve { curve })
    }

    /// Check if the engine is currently in passthrough (bit-perfect) mode.
    pub fn is_passthrough(&self) -> bool {
        self.callback_data.is_passthrough()
    }

    /// Check if the engine is currently in DoP (DSD over PCM) mode.
    pub fn is_dop(&self) -> bool {
        self.callback_data.is_dop()
    }

    /// Skip to next track with crossfade.
    pub fn skip_to_next(&self) -> Result<(), String> {
        self.send_command(AudioCommand::SkipToNext)
    }

    /// Set playback speed (0.5 to 2.0).
    pub fn set_playback_speed(&self, speed: f32) -> Result<(), String> {
        self.send_command(AudioCommand::SetPlaybackSpeed { speed })
    }

    /// Switch pipeline mode at runtime (used when Bit-perfect (DAP Internal) is toggled).
    pub fn set_pipeline_mode_passthrough(&self, passthrough: bool) -> Result<(), String> {
        self.send_command(AudioCommand::SetPipelineMode { passthrough })
    }

    /// Toggle experimental 432 Hz tuning. Breaks bit-perfect passthrough.
    pub fn set_432hz_tuning_enabled(&self, enabled: bool) {
        self.callback_data.set_432hz_tuning_enabled(enabled);
    }

    pub fn set_dop_override(&self, is_dop: bool) -> Result<(), String> {
        self.send_command(AudioCommand::SetDopOverride { is_dop })
    }

    /// Set EQ: enabled and a variable list of band specs (real per-type biquads).
    pub fn set_equalizer(&self, enabled: bool, specs: Vec<EqBandSpec>) -> Result<(), String> {
        self.send_command(AudioCommand::SetEqualizer { enabled, specs })
    }

    /// Set BS2B crossfeed level (Off/Default/Crossfeed/CrossfeedEasy).
    pub fn set_crossfeed(&self, level: CrossfeedLevel) -> Result<(), String> {
        self.send_command(AudioCommand::SetCrossfeed { level })
    }

    /// Set pitch shift in semitones (tempo preserved). 0 = bypass.
    pub fn set_pitch_shift(&self, semitones: f32) -> Result<(), String> {
        self.send_command(AudioCommand::SetPitchShift { semitones })
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

    /// Configure spatial/time FX settings.
    #[allow(clippy::too_many_arguments)]
    pub fn set_fx(
        &self,
        enabled: bool,
        balance: f32,
        tempo: f32,
        damp: f32,
        filter_hz: f32,
        delay_ms: f32,
        size: f32,
        mix: f32,
        feedback: f32,
        width: f32,
    ) -> Result<(), String> {
        self.send_command(AudioCommand::SetFx {
            enabled,
            balance,
            tempo,
            damp,
            filter_hz,
            delay_ms,
            size,
            mix,
            feedback,
            width,
        })
    }

    /// Enable/disable the impulse-response convolver and set its wet/dry mix.
    pub fn set_convolver(&self, enabled: bool, mix: f32) -> Result<(), String> {
        self.send_command(AudioCommand::SetConvolver { enabled, mix })
    }

    /// Load pre-decoded, pre-resampled IR coefficients into the convolver.
    /// `coeffs` is 1 (mono) or 2 (stereo L/R) tap vectors.
    pub fn set_convolver_ir(&self, coeffs: Vec<Vec<f32>>) -> Result<(), String> {
        self.send_command(AudioCommand::SetConvolverIr { coeffs })
    }

    /// Remove the current IR; convolver becomes a no-op until a new IR loads.
    pub fn clear_convolver_ir(&self) -> Result<(), String> {
        self.send_command(AudioCommand::ClearConvolverIr)
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

    pub fn output_runtime(&self) -> &AudioOutputRuntimeState {
        &self.output_runtime
    }

    pub fn audio_api_pref(&self) -> AudioApiPreference {
        self.audio_api_pref
    }

    /// Shutdown the engine.
    pub fn shutdown(&self) -> Result<(), String> {
        self.shutdown.store(true, Ordering::Release);
        self.send_command(AudioCommand::Shutdown)
            .inspect_err(|e| {
                log::warn!("Failed to send Shutdown command: {}", e);
            })
            .ok();
        if let Some(handle) = self._audio_thread.lock().take() {
            let _ = handle.join();
        }
        Ok(())
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
    format!(
        "native-shared:{}",
        preferred_sample_rate.unwrap_or_default()
    )
}

/// Initialize the audio engine and return a handle.
///
/// The actual cpal stream runs in a dedicated thread.
#[cfg(not(target_os = "android"))]
pub fn create_audio_engine(
    preferred_sample_rate: Option<u32>,
    _allow_dap_native: bool,
    _dap_bit_perfect_enabled: bool,
    _excluded_strategies: Vec<OutputStrategy>,
    audio_api_pref: AudioApiPreference,
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

    dev_eprintln!(
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
        PipelineMode::Dsp,
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
    let decoders = Arc::new(Mutex::new(Vec::<DecoderHandle>::new()));
    let decoders_clone = Arc::clone(&decoders);

    // Shutdown flag
    let shutdown = Arc::new(AtomicBool::new(false));
    let shutdown_clone = Arc::clone(&shutdown);

    // Callback data for command thread
    let callback_data_for_thread = Arc::clone(&callback_data);

    // Spawn the audio thread (which owns the cpal stream)
    let audio_thread = thread::Builder::new()
        .name("audio-engine".to_string())
        .spawn(move || {
            let event_tx_panic = event_tx.clone();
            let event_tx_build_err = event_tx.clone();
            let thread_body = move || {
                // Build the stream in this thread
                let stream = match device.build_output_stream(
                    &config,
                    move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                        audio_callback(data, &callback_data_clone, &event_tx_clone);
                    },
                    |err| {
                        dev_eprintln!("Audio stream error: {}", err);
                    },
                    None,
                ) {
                    Ok(s) => s,
                    Err(e) => {
                        dev_eprintln!("Failed to build audio stream: {}", e);
                        let _ = event_tx_build_err.try_send(AudioEvent::Error {
                            message: format!("Failed to build audio stream: {}", e),
                        });
                        return;
                    }
                };

                // Start the stream
                if let Err(e) = stream.play() {
                    dev_eprintln!("Failed to start audio stream: {}", e);
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
                    None,
                );

                // Stream will be dropped here when the loop exits
            };

            report_thread_panic(
                &event_tx_panic,
                std::panic::catch_unwind(std::panic::AssertUnwindSafe(thread_body)),
            );
        });

    let audio_thread = audio_thread.map_err(|e| format!("Failed to spawn audio thread: {}", e))?;

    Ok(AudioEngineHandle {
        callback_data,
        command_tx,
        event_rx,
        state,
        sample_rate: target_sample_rate,
        channels,
        output_signature: desired_output_signature(Some(target_sample_rate)),
        output_runtime: AudioOutputRuntimeState {
            strategy: OutputStrategy::MixerMatched.as_str().to_string(),
            requested_sample_rate: target_sample_rate,
            actual_sample_rate: target_sample_rate,
            resampler_active: false,
            passthrough_allowed: false,
            verification_reason: None,
            direct_usb_active: false,
            direct_usb_verified: false,
            dsd_source_rate: None,
            dsd_effective_mode: None,
            dsd_wire_rate: None,
            dsd_transport: None,
            active_audio_api: None,
        },
        audio_api_pref,
        decoders,
        shutdown,
        _audio_thread: parking_lot::Mutex::new(Some(audio_thread)),
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

    let dsd_suffix = match crate::api::audio_api::current_dsd_track_rate()
        .and_then(crate::audio::dsd_engine::dsd::DsdRate::from_sample_rate)
    {
        Some(rate) => {
            let mode = crate::api::audio_api::effective_dsd_output_mode(
                crate::api::audio_api::current_dsd_output_mode(),
            );
            match mode {
                crate::audio::dsd_engine::dsd::DsdOutputMode::Native => {
                    format!(":dsd-native:{}", rate.byte_rate())
                }
                crate::audio::dsd_engine::dsd::DsdOutputMode::Dop => {
                    format!(":dsd-dop:{}", rate.dop_carrier_rate())
                }
                _ => String::new(),
            }
        }
        None => String::new(),
    };

    format!(
        "android-shared:requested:{}{}",
        preferred_sample_rate.unwrap_or(48_000),
        dsd_suffix,
    )
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
fn android_output_signature_for_strategy(
    strategy: OutputStrategy,
    requested_sample_rate: u32,
) -> String {
    match strategy {
        OutputStrategy::DapNative => {
            format!("android-shared:dap-native:{}", requested_sample_rate)
        }
        OutputStrategy::MixerBitPerfect => {
            format!("android-shared:mixer-bit-perfect:{}", requested_sample_rate)
        }
        OutputStrategy::MixerMatched => {
            format!("android-shared:mixer-matched:{}", requested_sample_rate)
        }
        OutputStrategy::UsbDirect => {
            #[cfg(feature = "uac2")]
            {
                return android_direct_output_signature(Some(requested_sample_rate))
                    .unwrap_or_else(|| {
                        format!("android-uac2:requested:{}", requested_sample_rate)
                    });
            }

            #[cfg(not(feature = "uac2"))]
            {
                format!("android-uac2:requested:{}", requested_sample_rate)
            }
        }
        OutputStrategy::ResampledFallback => {
            format!(
                "android-shared:resampled-fallback:{}",
                requested_sample_rate
            )
        }
        OutputStrategy::DsdNative => {
            format!("android-shared:dsd-native:{}", requested_sample_rate)
        }
        OutputStrategy::DsdDoP => {
            format!("android-shared:dsd-dop:{}", requested_sample_rate)
        }
        OutputStrategy::UsbDsdNative => {
            format!("android-shared:usb-dsd-native:{}", requested_sample_rate)
        }
    }
}

#[cfg(target_os = "android")]
fn build_output_runtime_state(
    strategy: OutputStrategy,
    verification: OutputVerification,
    direct_usb_active: bool,
    direct_usb_verified: bool,
) -> AudioOutputRuntimeState {
    let dsd_source_rate = crate::api::audio_api::current_dsd_track_rate();
    let dsd_effective_mode = dsd_source_rate.map(|_| {
        let mode = crate::api::audio_api::effective_dsd_output_mode(
            crate::api::audio_api::current_dsd_output_mode(),
        );
        match mode {
            crate::audio::dsd_engine::dsd::DsdOutputMode::PcmDecimation => "pcm".to_string(),
            crate::audio::dsd_engine::dsd::DsdOutputMode::Dop => "dop".to_string(),
            crate::audio::dsd_engine::dsd::DsdOutputMode::Native => "native".to_string(),
            crate::audio::dsd_engine::dsd::DsdOutputMode::Auto => "auto".to_string(),
        }
    });
    let (dsd_wire_rate, dsd_transport) = if dsd_source_rate.is_some() {
        let wire_rate = verification.actual_rate;
        let transport = match strategy {
            OutputStrategy::DsdNative => {
                crate::audio::dsd_sas_shim::native_transport_name().to_string()
            }
            OutputStrategy::UsbDsdNative => {
                #[cfg(feature = "uac2")]
                {
                    let debug = crate::uac2::android_direct_debug_state();
                    let subslot = debug.transport_subslot_size.unwrap_or(4);
                    format!("usb-native-dsd-u{}x{}-bit", subslot, subslot * 8)
                }
                #[cfg(not(feature = "uac2"))]
                "usb-native-dsd".to_string()
            }
            OutputStrategy::DsdDoP => {
                if direct_usb_active {
                    #[cfg(feature = "uac2")]
                    {
                        let debug = crate::uac2::android_direct_debug_state();
                        let bits = debug.transport_bit_resolution.unwrap_or(24);
                        format!("usb-dop-{}-bit", bits)
                    }
                    #[cfg(not(feature = "uac2"))]
                    "usb-dop".to_string()
                } else {
                    "dap-dop".to_string()
                }
            }
            OutputStrategy::UsbDirect => "usb-pcm".to_string(),
            _ => "pcm".to_string(),
        };
        (Some(wire_rate), Some(transport))
    } else {
        (None, None)
    };
    AudioOutputRuntimeState {
        strategy: verification
            .resolved_strategy(strategy)
            .as_str()
            .to_string(),
        requested_sample_rate: verification.requested_rate,
        actual_sample_rate: verification.actual_rate,
        resampler_active: verification.resampler_active,
        passthrough_allowed: verification.bit_perfect,
        verification_reason: verification.reason,
        direct_usb_active,
        direct_usb_verified,
        dsd_source_rate,
        dsd_effective_mode,
        dsd_wire_rate,
        dsd_transport,
        active_audio_api: None,
    }
}

#[cfg(target_os = "android")]
enum AndroidManagedStreamKind {
    F32(AudioStreamAsync<Output, AndroidOutputCallbackF32>),
    I32(AudioStreamAsync<Output, AndroidOutputCallbackI32>),
    I32Pcm(AudioStreamAsync<Output, AndroidOutputCallbackI32Pcm>),
    I16(AudioStreamAsync<Output, AndroidOutputCallbackI16>),
}

#[cfg(target_os = "android")]
struct AndroidManagedStream {
    kind: AndroidManagedStreamKind,
    actual_sample_rate: u32,
    active_audio_api: &'static str,
    active_sharing: &'static str,
    sample_format: &'static str,
    exclusive_error: Option<String>,
}

#[cfg(target_os = "android")]
impl AndroidManagedStream {
    fn start(&mut self) -> Result<(), oboe::Error> {
        match &mut self.kind {
            AndroidManagedStreamKind::F32(s) => s.start(),
            AndroidManagedStreamKind::I32(s) => s.start(),
            AndroidManagedStreamKind::I32Pcm(s) => s.start(),
            AndroidManagedStreamKind::I16(s) => s.start(),
        }
    }

    fn stop(&mut self) -> Result<(), oboe::Error> {
        match &mut self.kind {
            AndroidManagedStreamKind::F32(s) => s.stop(),
            AndroidManagedStreamKind::I32(s) => s.stop(),
            AndroidManagedStreamKind::I32Pcm(s) => s.stop(),
            AndroidManagedStreamKind::I16(s) => s.stop(),
        }
    }
}

/// Owns the Android-managed Oboe output stream and reopens it when the system
/// tears it down (audio focus loss, phone call, route change). The shared
/// `AudioCallbackData` keeps the current source's read position and the decoder
/// threads stay alive, so a reopened stream resumes exactly where playback was
/// interrupted instead of jumping to another time.
#[cfg(target_os = "android")]
struct ManagedStreamSupervisor {
    stream: Option<AndroidManagedStream>,
    callback_data: Arc<AudioCallbackData>,
    event_tx: Sender<AudioEvent>,
    target_sample_rate: u32,
    prefer_exclusive: bool,
    use_integer: bool,
    audio_api_pref: AudioApiPreference,
    reopen_failures: u32,
    next_retry: Option<std::time::Instant>,
}

#[cfg(target_os = "android")]
impl ManagedStreamSupervisor {
    fn new(
        stream: AndroidManagedStream,
        callback_data: Arc<AudioCallbackData>,
        event_tx: Sender<AudioEvent>,
        target_sample_rate: u32,
        prefer_exclusive: bool,
        use_integer: bool,
        audio_api_pref: AudioApiPreference,
    ) -> Self {
        Self {
            stream: Some(stream),
            callback_data,
            event_tx,
            target_sample_rate,
            prefer_exclusive,
            use_integer,
            audio_api_pref,
            reopen_failures: 0,
            next_retry: None,
        }
    }

    fn start(&mut self) -> Result<(), oboe::Error> {
        match self.stream.as_mut() {
            Some(s) => s.start(),
            None => Ok(()),
        }
    }

    fn stop(&mut self) {
        if let Some(mut s) = self.stream.take() {
            let _ = s.stop();
        }
    }

    /// Drop the disconnected stream and open a fresh one with the same
    /// parameters. The source position is untouched, so the new stream
    /// continues from the interrupted sample.
    fn poll_restart(&mut self, shutdown: &AtomicBool) {
        if !self.callback_data.stream_restart_requested() {
            return;
        }
        if shutdown.load(Ordering::Acquire) {
            return;
        }
        if let Some(until) = self.next_retry {
            if std::time::Instant::now() < until {
                return;
            }
        }
        self.callback_data.clear_stream_restart_request();

        if let Some(mut old) = self.stream.take() {
            let _ = old.stop();
        }

        log::info!(
            "[ENGINE] Reopening Oboe output stream after interruption to resume at the interrupted position"
        );
        match open_android_output_stream(
            Arc::clone(&self.callback_data),
            self.event_tx.clone(),
            self.target_sample_rate,
            self.prefer_exclusive,
            self.use_integer,
            self.audio_api_pref,
        ) {
            Ok(mut new_stream) => match new_stream.start() {
                Ok(()) => {
                    self.reopen_failures = 0;
                    self.next_retry = None;
                    self.stream = Some(new_stream);
                    log::info!(
                        "[ENGINE] Oboe stream reopened; playback resumes from the interrupted position"
                    );
                }
                Err(error) => {
                    log::warn!(
                        "[ENGINE] Reopened Oboe stream failed to start: {} (will retry)",
                        error
                    );
                    self.schedule_backoff();
                }
            },
            Err(error) => {
                log::warn!("[ENGINE] Oboe stream reopen failed: {} (will retry)", error);
                self.schedule_backoff();
            }
        }
    }

    fn schedule_backoff(&mut self) {
        self.reopen_failures = self.reopen_failures.saturating_add(1);
        let delay_secs = match self.reopen_failures {
            1 => 0.2,
            2 => 0.5,
            3 => 1.0,
            4 => 2.0,
            _ => 5.0,
        };
        self.next_retry =
            Some(std::time::Instant::now() + std::time::Duration::from_secs_f64(delay_secs));
    }
}

#[cfg(not(target_os = "android"))]
struct ManagedStreamSupervisor;

#[cfg(target_os = "android")]
pub fn create_audio_engine(
    preferred_sample_rate: Option<u32>,
    allow_dap_native: bool,
    dap_bit_perfect_enabled: bool,
    excluded_strategies: Vec<OutputStrategy>,
    audio_api_pref: AudioApiPreference,
) -> Result<AudioEngineHandle, String> {
    let device_profile = current_device_profile();

    #[cfg(feature = "uac2")]
    let debug_state = android_direct_debug_state();
    #[cfg(feature = "uac2")]
    let will_attempt_usb = debug_state.registered;
    #[cfg(not(feature = "uac2"))]
    let will_attempt_usb = false;

    // Bogus track rates (lying M4A headers advertise 1 Hz) must never reach
    // an output stream config: the callback buffers collapse and the audio
    // thread dies. Treat them as "no preference" and use the platform default.
    let preferred_sample_rate =
        preferred_sample_rate.filter(|rate| crate::audio::decoder::plausible_sample_rate(*rate));

    // When a DAP device has bit-perfect disabled, force the output to
    // 48 kHz so that all DSP runs at a fixed rate and the in-app rubato
    // resampler does any rate conversion cleanly. The only exception is an
    // active DSD track, whose PCM target rate (176.4k/352.8k) must be
    // honoured to avoid a mismatch with the DSD decoder. Leaving a hi-res
    // PCM rate (e.g. 96k) here opens the engine at 96k and pushes the
    // 96->48 downsample onto the Android mixer, whose fast filter folds
    // ultrasonic energy back as aliasing — distorted and ~2x loud at any
    // app volume, because the conversion happens downstream of the gain.
    let dap_force_dsp = !dap_bit_perfect_enabled
        && device_profile.as_ref().is_some_and(|p| p.is_dap())
        && !will_attempt_usb;
    let mut requested_sample_rate = if dap_force_dsp {
        let dsd_active = crate::api::audio_api::current_dsd_track_rate().is_some();
        match preferred_sample_rate.filter(|&r| r > 0) {
            Some(rate) if dsd_active && rate > 48_000 => rate,
            _ => 48_000,
        }
    } else {
        preferred_sample_rate.filter(|&rate| rate > 0).unwrap_or(48_000)
    };

    #[cfg(feature = "uac2")]
    if will_attempt_usb {
        validate_android_direct_request(Some(requested_sample_rate))?;
    }

    let selected_output_device = select_android_output_device(requested_sample_rate)
        .or_else(|_| {
            // DSD Native and DoP bypass the Oboe stream entirely, so if
            // the byte/carrier rate isn't supported by any PCM device,
            // try a standard rate just to confirm a wired output exists.
            select_android_output_device(48_000)
        })
        .ok();
    let shared_supports_requested_rate = selected_output_device
        .as_ref()
        .map(|device| android_device_supports_sample_rate(device, requested_sample_rate))
        .unwrap_or(false);
    let confirmed_dap_native = allow_dap_native
        && dap_bit_perfect_enabled
        && selected_output_device.as_ref().is_some_and(|device| {
            device_profile.as_ref().is_some_and(|profile| {
                profile.confirmed_bit_perfect
                    && android_device_supports_dap_native_strategy(device.device_type)
            })
        });

    let dsd_rate = crate::api::audio_api::current_dsd_track_rate()
        .and_then(crate::audio::dsd_engine::dsd::DsdRate::from_sample_rate)
        .or_else(|| {
            crate::audio::dsd_engine::dsd::DsdRate::from_sample_rate(requested_sample_rate)
        });
    let supports_native_dsd = device_profile
        .as_ref()
        .is_some_and(|p| p.supports_native_dsd);

    let desired_strategy = if will_attempt_usb {
        let track_info = if let Some(rate) = dsd_rate {
            TrackInfo::dsd(rate.sample_rate(), ANDROID_DIRECT_CHANNELS)
        } else {
            TrackInfo::pcm(requested_sample_rate, ANDROID_DIRECT_CHANNELS)
        };
        #[cfg(feature = "uac2")]
        let usb_dsd_native_available = {
            let debug = android_direct_debug_state();
            debug.available_alt_settings.iter().any(|alt| {
                alt.format_tag == "DSD"
                    && alt.subslot_size > 0
                    && dsd_rate.is_some_and(|r| {
                        let wire = r.sample_rate() / (8 * u32::from(alt.subslot_size));
                        // UAC2 DSD alts don't carry rate ranges in the descriptor; the wire
                        // rate may not be enumerable. A DSD alt's presence is itself the
                        // capability signal — accept empty sample_rates rather than disqualify.
                        alt.sample_rates.is_empty()
                            || wire <= alt.sample_rates.iter().copied().max().unwrap_or(0)
                            || alt.sample_rates.iter().any(|&sr| sr == wire)
                    })
            })
        };
        #[cfg(not(feature = "uac2"))]
        let usb_dsd_native_available = false;

        #[cfg(feature = "uac2")]
        let (usb_dop_available, usb_max_carrier) = {
            let debug = android_direct_debug_state();
            let carrier = dsd_rate.map(|r| r.dop_carrier_rate()).unwrap_or(0);
            let has_pcm_24bit = debug.available_alt_settings.iter().any(|alt| {
                alt.format_tag == "PCM"
                    && alt.bit_resolution >= 24
                    && alt.sample_rates.iter().any(|&sr| sr == carrier)
            });
            (has_pcm_24bit, if has_pcm_24bit { carrier } else { 0 })
        };
        #[cfg(not(feature = "uac2"))]
        let (usb_dop_available, usb_max_carrier) = (false, 0u32);

        #[cfg(feature = "uac2")]
        {
            let dbg = android_direct_debug_state();
            let alt_summary: Vec<String> = dbg
                .available_alt_settings
                .iter()
                .map(|a| {
                    format!(
                        "{}({}b,ss{},{:?})",
                        a.format_tag, a.bit_resolution, a.subslot_size, a.sample_rates
                    )
                })
                .collect();
            dev_eprintln!(
                "[DSD-STRATEGY] dsd_rate={:?} native_avail={} dop_avail={} carrier={} registered={} | alts=[{}]",
                dsd_rate,
                usb_dsd_native_available,
                usb_dop_available,
                usb_max_carrier,
                dbg.registered,
                alt_summary.join(", ")
            );
        }

        select_strategy_excluded(
            &track_info,
            &DeviceCaps {
                api_level: None,
                confirmed_dap_native,
                direct_usb_available: true,
                direct_usb_verified: true,
                usb_supports_native_dsd: usb_dsd_native_available,
                supports_dop: usb_dop_available,
                max_dsd_carrier_rate: usb_max_carrier,
                ..DeviceCaps::default()
            },
            &excluded_strategies,
        )
    } else {
        let track_info = if let Some(rate) = dsd_rate {
            TrackInfo::dsd(rate.sample_rate(), ANDROID_DIRECT_CHANNELS)
        } else {
            TrackInfo::pcm(requested_sample_rate, ANDROID_DIRECT_CHANNELS)
        };
        select_strategy_excluded(
            &track_info,
            &DeviceCaps {
                api_level: None,
                confirmed_dap_native,
                supports_requested_rate: shared_supports_requested_rate,
                supports_native_dsd,
                supports_dop: supports_native_dsd,
                max_dsd_carrier_rate: if supports_native_dsd { 705_600 } else { 0 },
                ..DeviceCaps::default()
            },
            &excluded_strategies,
        )
    };

    // When the effective DSD output mode is DoP, force DsdDoP on the internal path.
    // DoP is carrier-rate PCM (24-bit) — a DAP can carry it if it plays the carrier
    // rate, regardless of ENCODING_DSD. The strategy scorer ties DoP capability to
    // supports_native_dsd, which incorrectly excludes DAPs that lack ENCODING_DSD
    // but can still pass DoP markers through their HAL/DAC.
    let effective_dsd_mode = crate::api::audio_api::effective_dsd_output_mode(
        crate::api::audio_api::current_dsd_output_mode(),
    );
    let desired_strategy = if dsd_rate.is_some()
        && !will_attempt_usb
        && effective_dsd_mode == crate::audio::dsd_engine::dsd::DsdOutputMode::Dop
        && !excluded_strategies.contains(&OutputStrategy::DsdDoP)
    {
        log::info!(
            "[DSD-STRATEGY] Effective DSD mode is DoP; forcing DsdDoP over {:?}",
            desired_strategy
        );
        OutputStrategy::DsdDoP
    } else {
        desired_strategy
    };

    // Override the sample rate for DSD strategies: the DSD Native
    // backend needs the byte rate (e.g. 705 600 Hz for DSD128),
    // DSD DoP needs the carrier rate (e.g. 352 800 Hz for DSD128),
    // and USB DSD Native needs the wire rate (e.g. 88 200 Hz for DSD64).
    match desired_strategy {
        OutputStrategy::DsdNative => {
            if let Some(rate) = dsd_rate {
                let byte_rate = rate.byte_rate();
                log::info!(
                    "[ENGINE] {:?}: overriding rate {} -> {} Hz (byte_rate)",
                    desired_strategy,
                    requested_sample_rate,
                    byte_rate,
                );
                requested_sample_rate = byte_rate;
            }
        }
        OutputStrategy::UsbDsdNative => {
            if let Some(rate) = dsd_rate {
                let wire_rate = rate.sample_rate() / 32; // DSD_U32 wire rate
                log::info!(
                    "[ENGINE] {:?}: overriding rate {} -> {} Hz (wire_rate, DSD_U32)",
                    desired_strategy,
                    requested_sample_rate,
                    wire_rate,
                );
                requested_sample_rate = wire_rate;
            }
        }
        OutputStrategy::DsdDoP => {
            if let Some(rate) = dsd_rate {
                let carrier = rate.dop_carrier_rate();
                log::info!(
                    "[ENGINE] DSD DoP: overriding rate {} -> {} Hz (carrier_rate)",
                    requested_sample_rate,
                    carrier,
                );
                requested_sample_rate = carrier;
            }
        }
        _ => {}
    }

    #[cfg(feature = "uac2")]
    let channels = {
        dev_eprintln!(
            "create_audio_engine: requested_rate={} Hz, strategy={:?}, debug_state: registered={}, effective_rate={:?}, requested_rate={:?}, effective_ch={:?}, requested_ch={:?}",
            requested_sample_rate,
            desired_strategy,
            debug_state.registered,
            debug_state.playback_format_sample_rate,
            debug_state.requested_playback_sample_rate,
            debug_state.playback_format_channels,
            debug_state.requested_playback_channels,
        );

        if !will_attempt_usb {
            ANDROID_DIRECT_CHANNELS
        } else {
            let effective_matches =
                debug_state.playback_format_sample_rate == Some(requested_sample_rate);
            let requested_matches =
                debug_state.requested_playback_sample_rate == Some(requested_sample_rate);

            let channels = if effective_matches {
                debug_state
                    .playback_format_channels
                    .map(|c| c as usize)
                    .unwrap_or(ANDROID_DIRECT_CHANNELS)
            } else if requested_matches {
                debug_state
                    .requested_playback_channels
                    .map(|c| c as usize)
                    .unwrap_or(ANDROID_DIRECT_CHANNELS)
            } else {
                ANDROID_DIRECT_CHANNELS
            };

            dev_eprintln!(
                "create_audio_engine: DAC registered, will attempt USB backend with {} channels (format_matches: effective={}, requested={})",
                channels, effective_matches, requested_matches
            );
            channels
        }
    };

    #[cfg(not(feature = "uac2"))]
    let channels = ANDROID_DIRECT_CHANNELS;

    // Create finished tracks channel (from audio callback to command thread)
    let (finished_tx, finished_rx) = bounded::<AudioSource>(32);

    // Create shared data before the output path is opened. If the platform
    // changes the actual stream rate, we reconfigure the processing state
    // before any playback commands are accepted.
    //
    // Pipeline mode is determined by desired strategy:
    // - UsbDirect / DapNative → Passthrough (verified below; downgraded on failure)
    // - All other strategies   → Dsp (full processing chain)
    let initial_pipeline_mode = match desired_strategy {
        OutputStrategy::UsbDirect
        | OutputStrategy::DapNative
        | OutputStrategy::DsdNative
        | OutputStrategy::UsbDsdNative => PipelineMode::Passthrough,
        _ => PipelineMode::Dsp,
    };
    let callback_data = Arc::new(AudioCallbackData::new(
        requested_sample_rate,
        channels,
        finished_tx,
        initial_pipeline_mode,
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
    let decoders = Arc::new(Mutex::new(Vec::<DecoderHandle>::new()));
    let decoders_clone = Arc::clone(&decoders);

    // Shutdown flag
    let shutdown = Arc::new(AtomicBool::new(false));
    let shutdown_clone = Arc::clone(&shutdown);

    // Callback data for command thread
    let callback_data_for_thread = Arc::clone(&callback_data);

    #[cfg(feature = "uac2")]
    let mut direct_usb_backend = None;

    let mut dsd_native_backend = None;

    // Raw ALSA S32_LE fallback — /dev/snd direct write (EACCES on HiBy).
    let mut pcm_alsa_backend = None;
    let mut dap_alsa_error: Option<String> = None;

    // Native AudioTrack DIRECT — the UAPP mixer-bypass method.
    #[cfg(target_os = "android")]
    let mut audiotrack_backend = None;
    let mut dap_audiotrack_error: Option<String> = None;

    let mut final_sample_rate = requested_sample_rate;
    let mut output_runtime = build_output_runtime_state(
        desired_strategy,
        OutputVerification::verify(requested_sample_rate, requested_sample_rate, false, true),
        false,
        false,
    );
    let mut output_signature =
        android_output_signature_for_strategy(desired_strategy, requested_sample_rate);

    #[cfg(feature = "uac2")]
    if desired_strategy == OutputStrategy::UsbDirect
        || desired_strategy == OutputStrategy::UsbDsdNative
        || desired_strategy == OutputStrategy::DsdDoP
    {
        if desired_strategy == OutputStrategy::UsbDsdNative {
            if let Some(rate) = dsd_rate {
                let _ = crate::uac2::set_android_usb_dsd_native_mode(rate.sample_rate());
            }
        } else if desired_strategy == OutputStrategy::DsdDoP {
            if let Some(rate) = dsd_rate {
                let carrier = rate.dop_carrier_rate();
                let dop_bits = rate.dop_bits_per_frame();
                let _ = crate::uac2::set_android_usb_dop_mode(true, carrier, dop_bits);
            }
        }
        match create_android_usb_backend(
            Arc::clone(&callback_data_clone),
            event_tx_clone.clone(),
            requested_sample_rate,
        ) {
            Ok(Some(mut backend)) => {
                let debug_state = android_direct_debug_state();
                let actual_sample_rate = debug_state
                    .clock_reported_sample_rate
                    .filter(|&rate| rate > 0)
                    .or(debug_state.playback_format_sample_rate)
                    .filter(|&rate| rate > 0)
                    .or(debug_state.requested_playback_sample_rate)
                    .filter(|&rate| rate > 0)
                    .unwrap_or(requested_sample_rate);
                let verification = OutputVerification::verify(
                    requested_sample_rate,
                    actual_sample_rate,
                    true,
                    debug_state.clock_verification_passed,
                );

                // ponytail: keep the direct-USB backend even when verification
                // fails or bit-perfect is off. The Pixel USB audio HAL stutters
                // (same path ExoPlayer uses); the app's own UAC2 driver is the
                // only click-free route. bit-perfect + verified => Passthrough;
                // otherwise run the DSP chain over direct USB. The decoder
                // resamples the track to actual_sample_rate, so a rate mismatch
                // stays pitch-correct, just not sample-identical.
                final_sample_rate = actual_sample_rate;
                callback_data.reconfigure_sample_rate(final_sample_rate);
                let bit_perfect_pipeline =
                    dap_bit_perfect_enabled && verification.bit_perfect;
                if desired_strategy == OutputStrategy::UsbDsdNative
                    || desired_strategy == OutputStrategy::DsdDoP
                {
                    callback_data.set_pipeline_mode(PipelineMode::Dop);
                } else if bit_perfect_pipeline {
                    callback_data.set_pipeline_mode(PipelineMode::Passthrough);
                } else {
                    if !verification.bit_perfect {
                        let reason = verification
                            .reason
                            .clone()
                            .unwrap_or_else(|| "USB direct verification failed".to_string());
                        log::info!(
                            "[ENGINE] USB direct non-bit-perfect ({}). Keeping direct USB with DSP.",
                            reason
                        );
                    }
                    callback_data.set_pipeline_mode(PipelineMode::Dsp);
                }
                output_runtime = build_output_runtime_state(
                    desired_strategy,
                    verification,
                    true,
                    debug_state.clock_verification_passed,
                );
                output_signature = android_output_signature_for_strategy(
                    desired_strategy,
                    requested_sample_rate,
                );
                direct_usb_backend = Some(backend);
            }
            Ok(None) => {
                log::warn!(
                    "[ENGINE] Android direct USB was selected for {} Hz but no backend was created; falling back to Android-managed output",
                    requested_sample_rate
                );
                output_runtime.verification_reason = Some(
                    "USB direct backend was unavailable; Android-managed fallback active"
                        .to_string(),
                );
                output_runtime.strategy = OutputStrategy::ResampledFallback.as_str().to_string();
                output_signature = android_output_signature_for_strategy(
                    OutputStrategy::ResampledFallback,
                    requested_sample_rate,
                );
            }
            Err(error) => {
                log::warn!(
                    "[ENGINE] Android direct USB init failed: {}. Falling back to Android-managed output.",
                    error
                );
                output_runtime.verification_reason = Some(error);
                output_runtime.strategy = OutputStrategy::ResampledFallback.as_str().to_string();
                output_signature = android_output_signature_for_strategy(
                    OutputStrategy::ResampledFallback,
                    requested_sample_rate,
                );
            }
        }
    }

    // DSD Native: ALSA direct only; on failure map to DoP via audio_api.rs.
    #[cfg(target_os = "android")]
    if desired_strategy == OutputStrategy::DsdNative && direct_usb_backend.is_none() {
        match crate::audio::dsd_native_backend::DsdNativeBackend::start(
            Arc::clone(&callback_data_clone),
            event_tx_clone.clone(),
            requested_sample_rate,
            channels,
        ) {
            Ok(backend) => {
                log::info!(
                    "[ENGINE] DSD Native backend created at {} Hz (via {})",
                    requested_sample_rate,
                    backend.transport_name()
                );
                crate::api::audio_api::clear_dsd_native_failure();
                final_sample_rate = requested_sample_rate;
                callback_data.reconfigure_sample_rate(final_sample_rate);
                callback_data.set_pipeline_mode(PipelineMode::Dop);
                output_runtime = build_output_runtime_state(
                    OutputStrategy::DsdNative,
                    OutputVerification::verify(
                        requested_sample_rate,
                        requested_sample_rate,
                        true,
                        true,
                    ),
                    false,
                    false,
                );
                output_signature = android_output_signature_for_strategy(
                    OutputStrategy::DsdNative,
                    requested_sample_rate,
                );
                dsd_native_backend = Some(backend);
            }
            Err(error) => {
                log::warn!(
                    "[ENGINE] DSD Native init failed (ALSA + ENCODING_DSD): {}. Will fall back to DoP/PCM.",
                    error
                );
                return Err(format!("DSD_NATIVE_FALLBACK:{}", error));
            }
        }
    }

    // DapNative PCM: mixer-bypassing direct paths first, managed fallback last.
    #[cfg(target_os = "android")]
    if desired_strategy == OutputStrategy::DapNative
        && dap_bit_perfect_enabled
        && direct_usb_backend.is_none()
        && dsd_native_backend.is_none()
    {
        match crate::audio::audiotrack_direct::AudioTrackDirectBackend::start(
            Arc::clone(&callback_data_clone),
            event_tx_clone.clone(),
            requested_sample_rate,
            channels,
        ) {
            Ok(backend) => {
                log::info!(
                    "[ENGINE] DAP native PCM via AudioTrack DIRECT at {} Hz — mixer bypassed",
                    requested_sample_rate
                );
                final_sample_rate = requested_sample_rate;
                callback_data.reconfigure_sample_rate(final_sample_rate);
                callback_data.set_pipeline_mode(PipelineMode::Passthrough);
                output_runtime = build_output_runtime_state(
                    OutputStrategy::DapNative,
                    OutputVerification::verify(
                        requested_sample_rate,
                        requested_sample_rate,
                        true,
                        true,
                    ),
                    false,
                    false,
                );
                output_signature = format!("android-direct:dap-native:{}", requested_sample_rate);
                audiotrack_backend = Some(backend);
            }
            Err(error) => {
                log::info!(
                    "[ENGINE] DAP native AudioTrack DIRECT unavailable ({}). Trying ALSA direct.",
                    error
                );
                dap_audiotrack_error = Some(error);
            }
        }
    }

    #[cfg(target_os = "android")]
    if desired_strategy == OutputStrategy::DapNative
        && dap_bit_perfect_enabled
        && direct_usb_backend.is_none()
        && dsd_native_backend.is_none()
        && audiotrack_backend.is_none()
    {
        match crate::audio::dsd_native_backend::PcmAlsaBackend::start(
            Arc::clone(&callback_data_clone),
            event_tx_clone.clone(),
            requested_sample_rate,
            channels,
        ) {
            Ok(backend) => {
                log::info!(
                    "[ENGINE] DAP native PCM via ALSA direct at {} Hz — AudioFlinger bypassed",
                    requested_sample_rate
                );
                final_sample_rate = requested_sample_rate;
                callback_data.reconfigure_sample_rate(final_sample_rate);
                callback_data.set_pipeline_mode(PipelineMode::Passthrough);
                output_runtime = build_output_runtime_state(
                    OutputStrategy::DapNative,
                    OutputVerification::verify(
                        requested_sample_rate,
                        requested_sample_rate,
                        true,
                        true,
                    ),
                    false,
                    false,
                );
                output_signature = format!("android-alsa:dap-native:{}", requested_sample_rate);
                pcm_alsa_backend = Some(backend);
            }
            Err(error) => {
                log::info!(
                    "[ENGINE] DAP native ALSA direct unavailable ({}). Using Android-managed output.",
                    error
                );
                dap_alsa_error = Some(error);
            }
        }
    }

    let mut managed_stream = None;
    // Hoisted so the audio thread can reopen the managed Oboe stream with the
    // same parameters after an interruption (preserving the playback position).
    let mut managed_prefer_exclusive = false;
    let mut managed_use_integer = false;
    #[cfg(feature = "uac2")]
    #[cfg(target_os = "android")]
    let use_managed_fallback = direct_usb_backend.is_none()
        && dsd_native_backend.is_none()
        && pcm_alsa_backend.is_none()
        && audiotrack_backend.is_none();
    #[cfg(feature = "uac2")]
    #[cfg(not(target_os = "android"))]
    let use_managed_fallback = direct_usb_backend.is_none() && dsd_native_backend.is_none();
    #[cfg(not(feature = "uac2"))]
    #[cfg(target_os = "android")]
    let use_managed_fallback = dsd_native_backend.is_none()
        && pcm_alsa_backend.is_none()
        && audiotrack_backend.is_none();
    #[cfg(not(feature = "uac2"))]
    #[cfg(not(target_os = "android"))]
    let use_managed_fallback = dsd_native_backend.is_none();

    if use_managed_fallback {
        let desired_shared_strategy = if desired_strategy == OutputStrategy::UsbDirect
            || desired_strategy == OutputStrategy::UsbDsdNative
        {
            OutputStrategy::ResampledFallback
        } else {
            desired_strategy
        };
        managed_prefer_exclusive = dap_bit_perfect_enabled
            && device_profile.as_ref().is_some_and(|p| p.is_dap())
            && !will_attempt_usb;
        let is_dsd_dop =
            dsd_rate.is_some() && matches!(desired_shared_strategy, OutputStrategy::DsdDoP);
        managed_use_integer = is_dsd_dop || desired_shared_strategy.is_dsd();
        let managed = open_android_output_stream(
            Arc::clone(&callback_data_clone),
            event_tx_clone.clone(),
            requested_sample_rate,
            managed_prefer_exclusive,
            managed_use_integer,
            audio_api_pref,
        )?;
        // Bit-perfect requires Exclusive: Shared goes through the mixer,
        // which silently resamples to the primary rate on many DAPs.
        let route_verified = match desired_shared_strategy {
            OutputStrategy::DapNative | OutputStrategy::DsdDoP => {
                managed.active_sharing != "shared"
            }
            _ => true,
        };
        let verification = OutputVerification::verify(
            requested_sample_rate,
            managed.actual_sample_rate,
            desired_shared_strategy.requests_passthrough(),
            route_verified,
        );
        let resolved_shared_strategy = verification.resolved_strategy(desired_shared_strategy);
        final_sample_rate = managed.actual_sample_rate;
        callback_data.reconfigure_sample_rate(final_sample_rate);
        if verification.bit_perfect && !dap_force_dsp {
            callback_data.set_pipeline_mode(PipelineMode::Passthrough);
        } else {
            callback_data.set_pipeline_mode(PipelineMode::Dsp);
        }
        if is_dsd_dop {
            callback_data.set_pipeline_mode(PipelineMode::Dop);
        }
        output_runtime =
            build_output_runtime_state(desired_shared_strategy, verification, false, false);
        output_runtime.active_audio_api = Some(managed.active_audio_api.to_string());
        if desired_shared_strategy == OutputStrategy::DapNative {
            let alsa_note = dap_alsa_error
                .as_deref()
                .map(|e| format!("; ALSA direct: {}", e))
                .unwrap_or_default();
            let audiotrack_note = dap_audiotrack_error
                .as_deref()
                .map(|e| format!("; AudioTrack direct: {}", e))
                .unwrap_or_default();
            let exclusive_note = managed
                .exclusive_error
                .as_deref()
                .map(|e| format!("; exclusive attempts: {}", e))
                .unwrap_or_default();
            output_runtime.verification_reason = Some(format!(
                "managed stream sharing={} pcm={} at {} Hz{}{}{}",
                managed.active_sharing,
                managed.sample_format,
                managed.actual_sample_rate,
                audiotrack_note,
                alsa_note,
                exclusive_note
            ));
        }
        if dsd_rate.is_some()
            && effective_dsd_mode == crate::audio::dsd_engine::dsd::DsdOutputMode::Dop
            && dsd_native_backend.is_none()
        {
            let native_failure_note = crate::api::audio_api::last_dsd_native_failure()
                .map(|reason| format!(" Native attempt failed: {}.", reason))
                .unwrap_or_default();
            output_runtime.verification_reason = Some(format!(
                "DoP active (bit-perfect DSD). Native DSD unavailable on this device.{}",
                native_failure_note
            ));
        }
        // Verified-exclusive DapNative rides the HAL direct_pcm profile
        // (mixer bypass); give it its own signature so reuse + diagnostics
        // can tell it apart from the shared/mixer path.
        output_signature = if desired_shared_strategy == OutputStrategy::DapNative
            && resolved_shared_strategy == OutputStrategy::DapNative
            && managed.active_sharing == "exclusive"
        {
            format!("android-direct:dap-native:{}", requested_sample_rate)
        } else {
            android_output_signature_for_strategy(resolved_shared_strategy, requested_sample_rate)
        };
        managed_stream = Some(managed);
    }

    log::info!(
        "[ENGINE] requested_rate_hz={} actual_rate_hz={} strategy={} resampler_active={} passthrough_allowed={} channels={} dap_profile={:?} audio_api_pref={} active_audio_api={:?} sharing={}",
        requested_sample_rate,
        final_sample_rate,
        output_runtime.strategy,
        output_runtime.resampler_active,
        output_runtime.passthrough_allowed,
        channels,
        device_profile.as_ref().map(|profile| &profile.kind),
        audio_api_pref.as_str(),
        output_runtime.active_audio_api,
        managed_stream.as_ref().map(|s| s.active_sharing).unwrap_or("n/a"),
    );

    // Spawn the audio thread (which owns the Oboe stream)
    let audio_thread = thread::Builder::new()
        .name("audio-engine".to_string())
        .spawn(move || {
            let event_tx_panic = event_tx.clone();
            // Body stays at original indentation; wrapping it just to re-indent
            // 130 lines would churn the diff.
            let thread_body = std::panic::AssertUnwindSafe(move || {
            #[cfg(feature = "uac2")]
            let mut direct_usb_backend = direct_usb_backend;
            let mut dsd_native_backend = dsd_native_backend;
            let mut pcm_alsa_backend = pcm_alsa_backend;
            #[cfg(target_os = "android")]
            let mut audiotrack_backend = audiotrack_backend;
            let mut managed_stream = managed_stream;

            #[cfg(feature = "uac2")]
            if direct_usb_backend.is_some() {
                command_processing_loop(
                    command_rx,
                    finished_rx,
                    event_tx,
                    callback_data_for_thread,
                    state_clone,
                    decoders_clone,
                    final_sample_rate,
                    shutdown_clone,
                    None,
                );

                if let Some(mut backend) = direct_usb_backend.take() {
                    let _ = backend.stop();
                }
                return;
            }

            #[cfg(target_os = "android")]
            if dsd_native_backend.is_some() {
                command_processing_loop(
                    command_rx,
                    finished_rx,
                    event_tx,
                    callback_data_for_thread,
                    state_clone,
                    decoders_clone,
                    final_sample_rate,
                    shutdown_clone,
                    None,
                );

                if let Some(mut backend) = dsd_native_backend.take() {
                    backend.stop();
                }
                return;
            }
            #[cfg(not(target_os = "android"))]
            let _ = dsd_native_backend;

            #[cfg(target_os = "android")]
            if audiotrack_backend.is_some() {
                command_processing_loop(
                    command_rx,
                    finished_rx,
                    event_tx,
                    callback_data_for_thread,
                    state_clone,
                    decoders_clone,
                    final_sample_rate,
                    shutdown_clone,
                    None,
                );

                if let Some(mut backend) = audiotrack_backend.take() {
                    backend.stop();
                }
                return;
            }

            #[cfg(target_os = "android")]
            if pcm_alsa_backend.is_some() {
                command_processing_loop(
                    command_rx,
                    finished_rx,
                    event_tx,
                    callback_data_for_thread,
                    state_clone,
                    decoders_clone,
                    final_sample_rate,
                    shutdown_clone,
                    None,
                );

                if let Some(mut backend) = pcm_alsa_backend.take() {
                    backend.stop();
                }
                return;
            }
            #[cfg(not(target_os = "android"))]
            let _ = pcm_alsa_backend;

            let mut supervisor = match managed_stream.take() {
                Some(stream) => ManagedStreamSupervisor::new(
                    stream,
                    Arc::clone(&callback_data_for_thread),
                    event_tx.clone(),
                    final_sample_rate,
                    managed_prefer_exclusive,
                    managed_use_integer,
                    audio_api_pref,
                ),
                None => {
                    let _ = event_tx.try_send(AudioEvent::Error {
                        message: "No Android managed output stream was prepared".to_string(),
                    });
                    return;
                }
            };

            if let Err(error) = supervisor.start() {
                dev_eprintln!("Failed to start Android managed output stream: {}", error);
                let _ = event_tx.try_send(AudioEvent::Error {
                    message: format!(
                        "Failed to start Android managed output stream: {}",
                        error
                    ),
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
                final_sample_rate,
                shutdown_clone,
                Some(&mut supervisor),
            );

            supervisor.stop();
            });
            report_thread_panic(
                &event_tx_panic,
                std::panic::catch_unwind(thread_body),
            );
        });

    let audio_thread = audio_thread.map_err(|e| format!("Failed to spawn audio thread: {}", e))?;

    Ok(AudioEngineHandle {
        callback_data,
        command_tx,
        event_rx,
        state,
        sample_rate: final_sample_rate,
        channels,
        output_signature,
        output_runtime,
        audio_api_pref,
        decoders,
        shutdown,
        _audio_thread: parking_lot::Mutex::new(Some(audio_thread)),
    })
}

#[cfg(target_os = "android")]
struct AndroidOutputCallbackF32 {
    callback_data: Arc<AudioCallbackData>,
    event_tx: Sender<AudioEvent>,
    scratch: Vec<f32>,
}

#[cfg(target_os = "android")]
impl AndroidOutputCallbackF32 {
    fn new(callback_data: Arc<AudioCallbackData>, event_tx: Sender<AudioEvent>) -> Self {
        Self {
            callback_data,
            event_tx,
            scratch: vec![0.0; ANDROID_DIRECT_SCRATCH_SAMPLES],
        }
    }
}

#[cfg(target_os = "android")]
impl AudioOutputCallback for AndroidOutputCallbackF32 {
    type FrameType = (f32, Stereo);

    fn on_error_before_close(
        &mut self,
        audio_stream: &mut dyn AudioOutputStreamSafe,
        error: oboe::Error,
    ) {
        dev_eprintln!(
            "Android managed output error before close: {:?} (device_id={}, sample_rate={} Hz, sharing={:?}, api={:?})",
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
        dev_eprintln!(
            "Android managed output error after close: {:?} (device_id={}, sample_rate={} Hz, sharing={:?}, api={:?})",
            error,
            audio_stream.get_device_id(),
            audio_stream.get_sample_rate(),
            audio_stream.get_sharing_mode(),
            audio_stream.get_audio_api(),
        );
        self.callback_data.request_stream_restart();
    }

    fn on_audio_ready(
        &mut self,
        _audio_stream: &mut dyn AudioOutputStreamSafe,
        audio_data: &mut [(f32, f32)],
    ) -> DataCallbackResult {
        let required_samples = audio_data.len() * ANDROID_DIRECT_CHANNELS;

        if required_samples > self.scratch.len() {
            dev_eprintln!(
                "[oboe] burst {} frames > scratch {} frames — growing scratch",
                audio_data.len(),
                self.scratch.len() / ANDROID_DIRECT_CHANNELS,
            );
            self.scratch.resize(required_samples, 0.0);
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

/// Integer callback for DoP / native DSD transport over AAudio I32.
/// Reads f32 samples from the decoder pipeline, extracts the raw bit
/// patterns (which carry DoP markers / DSD bytes), and writes them as
/// i32 to the AAudio HAL. No gain, format conversion, or DSP is applied.
#[cfg(target_os = "android")]
struct AndroidOutputCallbackI32 {
    callback_data: Arc<AudioCallbackData>,
    event_tx: Sender<AudioEvent>,
    scratch: Vec<f32>,
}

#[cfg(target_os = "android")]
impl AndroidOutputCallbackI32 {
    fn new(callback_data: Arc<AudioCallbackData>, event_tx: Sender<AudioEvent>) -> Self {
        Self {
            callback_data,
            event_tx,
            scratch: vec![0.0; ANDROID_DIRECT_SCRATCH_SAMPLES],
        }
    }
}

#[cfg(target_os = "android")]
impl AudioOutputCallback for AndroidOutputCallbackI32 {
    type FrameType = (i32, Stereo);

    fn on_error_before_close(
        &mut self,
        audio_stream: &mut dyn AudioOutputStreamSafe,
        error: oboe::Error,
    ) {
        dev_eprintln!(
            "Android managed i32 output error before close: {:?} (device_id={}, sample_rate={} Hz, sharing={:?}, api={:?})",
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
        dev_eprintln!(
            "Android managed i32 output error after close: {:?} (device_id={}, sample_rate={} Hz, sharing={:?}, api={:?})",
            error,
            audio_stream.get_device_id(),
            audio_stream.get_sample_rate(),
            audio_stream.get_sharing_mode(),
            audio_stream.get_audio_api(),
        );
        self.callback_data.request_stream_restart();
    }

    fn on_audio_ready(
        &mut self,
        _audio_stream: &mut dyn AudioOutputStreamSafe,
        audio_data: &mut [(i32, i32)],
    ) -> DataCallbackResult {
        let required_samples = audio_data.len() * ANDROID_DIRECT_CHANNELS;

        if required_samples > self.scratch.len() {
            dev_eprintln!(
                "[oboe-i32] burst {} frames > scratch {} frames — growing scratch",
                audio_data.len(),
                self.scratch.len() / ANDROID_DIRECT_CHANNELS,
            );
            self.scratch.resize(required_samples, 0.0);
        }

        let scratch = &mut self.scratch[..required_samples];
        audio_callback(scratch, &self.callback_data, &self.event_tx);

        for (frame_index, frame) in audio_data.iter_mut().enumerate() {
            let sample_index = frame_index * ANDROID_DIRECT_CHANNELS;
            let l = scratch[sample_index].to_bits() as i32;
            let r = scratch[sample_index + 1].to_bits() as i32;
            *frame = (l, r);
        }

        DataCallbackResult::Continue
    }
}

/// Linear PCM i32 callback for direct-PCM output (UAPP-proven on HiBy R4).
#[cfg(target_os = "android")]
struct AndroidOutputCallbackI32Pcm {
    callback_data: Arc<AudioCallbackData>,
    event_tx: Sender<AudioEvent>,
    scratch: Vec<f32>,
}

#[cfg(target_os = "android")]
impl AndroidOutputCallbackI32Pcm {
    fn new(callback_data: Arc<AudioCallbackData>, event_tx: Sender<AudioEvent>) -> Self {
        Self {
            callback_data,
            event_tx,
            scratch: vec![0.0; ANDROID_DIRECT_SCRATCH_SAMPLES],
        }
    }
}

#[cfg(target_os = "android")]
fn f32_to_i32(sample: f32) -> i32 {
    // `as` saturates; the clamp only pins +2^31 (not representable) to i32::MAX.
    let scaled = (sample * 2_147_483_648.0f32).round();
    if scaled >= 2_147_483_648.0f32 {
        i32::MAX
    } else {
        scaled as i32
    }
}

#[cfg(target_os = "android")]
impl AudioOutputCallback for AndroidOutputCallbackI32Pcm {
    type FrameType = (i32, Stereo);

    fn on_error_before_close(
        &mut self,
        audio_stream: &mut dyn AudioOutputStreamSafe,
        error: oboe::Error,
    ) {
        dev_eprintln!(
            "Android managed pcm-i32 output error before close: {:?} (device_id={}, sample_rate={} Hz, sharing={:?}, api={:?})",
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
        dev_eprintln!(
            "Android managed pcm-i32 output error after close: {:?} (device_id={}, sample_rate={} Hz, sharing={:?}, api={:?})",
            error,
            audio_stream.get_device_id(),
            audio_stream.get_sample_rate(),
            audio_stream.get_sharing_mode(),
            audio_stream.get_audio_api(),
        );
        self.callback_data.request_stream_restart();
    }

    fn on_audio_ready(
        &mut self,
        _audio_stream: &mut dyn AudioOutputStreamSafe,
        audio_data: &mut [(i32, i32)],
    ) -> DataCallbackResult {
        let required_samples = audio_data.len() * ANDROID_DIRECT_CHANNELS;

        if required_samples > self.scratch.len() {
            dev_eprintln!(
                "[oboe-pcm-i32] burst {} frames > scratch {} frames — growing scratch",
                audio_data.len(),
                self.scratch.len() / ANDROID_DIRECT_CHANNELS,
            );
            self.scratch.resize(required_samples, 0.0);
        }

        let scratch = &mut self.scratch[..required_samples];
        audio_callback(scratch, &self.callback_data, &self.event_tx);

        for (frame_index, frame) in audio_data.iter_mut().enumerate() {
            let sample_index = frame_index * ANDROID_DIRECT_CHANNELS;
            *frame = (
                f32_to_i32(scratch[sample_index]),
                f32_to_i32(scratch[sample_index + 1]),
            );
        }

        DataCallbackResult::Continue
    }
}

/// Integer i16 callback for exclusive direct-PCM (PCM_16-only direct profiles).
#[cfg(target_os = "android")]
struct AndroidOutputCallbackI16 {
    callback_data: Arc<AudioCallbackData>,
    event_tx: Sender<AudioEvent>,
    scratch: Vec<f32>,
}

#[cfg(target_os = "android")]
impl AndroidOutputCallbackI16 {
    fn new(callback_data: Arc<AudioCallbackData>, event_tx: Sender<AudioEvent>) -> Self {
        Self {
            callback_data,
            event_tx,
            scratch: vec![0.0; ANDROID_DIRECT_SCRATCH_SAMPLES],
        }
    }
}

#[cfg(target_os = "android")]
fn f32_to_i16(sample: f32) -> i16 {
    (sample * 32768.0).round().clamp(-32768.0, 32767.0) as i16
}

#[cfg(target_os = "android")]
impl AudioOutputCallback for AndroidOutputCallbackI16 {
    type FrameType = (i16, Stereo);

    fn on_error_before_close(
        &mut self,
        audio_stream: &mut dyn AudioOutputStreamSafe,
        error: oboe::Error,
    ) {
        dev_eprintln!(
            "Android managed i16 output error before close: {:?} (device_id={}, sample_rate={} Hz, sharing={:?}, api={:?})",
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
        dev_eprintln!(
            "Android managed i16 output error after close: {:?} (device_id={}, sample_rate={} Hz, sharing={:?}, api={:?})",
            error,
            audio_stream.get_device_id(),
            audio_stream.get_sample_rate(),
            audio_stream.get_sharing_mode(),
            audio_stream.get_audio_api(),
        );
        self.callback_data.request_stream_restart();
    }

    fn on_audio_ready(
        &mut self,
        _audio_stream: &mut dyn AudioOutputStreamSafe,
        audio_data: &mut [(i16, i16)],
    ) -> DataCallbackResult {
        let required_samples = audio_data.len() * ANDROID_DIRECT_CHANNELS;

        if required_samples > self.scratch.len() {
            dev_eprintln!(
                "[oboe-i16] burst {} frames > scratch {} frames — growing scratch",
                audio_data.len(),
                self.scratch.len() / ANDROID_DIRECT_CHANNELS,
            );
            self.scratch.resize(required_samples, 0.0);
        }

        let scratch = &mut self.scratch[..required_samples];
        audio_callback(scratch, &self.callback_data, &self.event_tx);

        for (frame_index, frame) in audio_data.iter_mut().enumerate() {
            let sample_index = frame_index * ANDROID_DIRECT_CHANNELS;
            *frame = (
                f32_to_i16(scratch[sample_index]),
                f32_to_i16(scratch[sample_index + 1]),
            );
        }

        DataCallbackResult::Continue
    }
}

/// PCM payload variants tried by the managed open loop hunting a direct output.
#[cfg(target_os = "android")]
#[derive(Clone, Copy, PartialEq, Eq)]
enum ManagedPcmFormat {
    S32,
    S16,
    F32,
}

#[cfg(target_os = "android")]
impl ManagedPcmFormat {
    fn label(self) -> &'static str {
        match self {
            ManagedPcmFormat::S32 => "pcm-i32",
            ManagedPcmFormat::S16 => "i16",
            ManagedPcmFormat::F32 => "f32",
        }
    }
}

#[cfg(target_os = "android")]
fn open_android_output_stream(
    callback_data: Arc<AudioCallbackData>,
    event_tx: Sender<AudioEvent>,
    target_sample_rate: u32,
    prefer_exclusive: bool,
    use_integer_format: bool,
    audio_api_pref: AudioApiPreference,
) -> Result<AndroidManagedStream, String> {
    let selected_device = select_android_output_device(target_sample_rate)?;
    let is_bluetooth = matches!(
        selected_device.device_type,
        AudioDeviceType::BluetoothA2DP
            | AudioDeviceType::BluetoothSCO
            | AudioDeviceType::BleBroadcast
            | AudioDeviceType::BleHeadset
            | AudioDeviceType::BleSpeaker
            | AudioDeviceType::HearingAid
    );
    let bit_perfect_route = prefer_exclusive && !is_bluetooth;
    let frames_per_callback = if is_bluetooth {
        0
    } else {
        android_frames_per_callback(target_sample_rate)
    };
    let sharing_modes: &[SharingMode] = if prefer_exclusive && !is_bluetooth {
        &[SharingMode::Exclusive, SharingMode::Shared]
    } else {
        &[SharingMode::Shared]
    };
    let attempts: Vec<AudioApi> = audio_api_attempts(audio_api_pref, is_bluetooth);
    let performance_mode = if is_bluetooth {
        PerformanceMode::None
    } else {
        PerformanceMode::LowLatency
    };

    let mut last_error = None;
    let mut fallback_kind = None;
    let mut fallback_rate = 0u32;
    let mut fallback_api: Option<&'static str> = None;
    let mut fallback_sharing: Option<&'static str> = None;
    let mut fallback_format: Option<&'static str> = None;
    let mut exclusive_notes: Vec<String> = Vec::new();

    for &sharing_mode in sharing_modes {
        for &audio_api in &attempts {
            // On a bit-perfect route we try integer formats before f32 when
            // requesting Exclusive: the HiBy R4 only grants a direct
            // (mixer-bypassing) output to a PCM_32 request at the native
            // rate — exactly how UAPP does it — with i16 as a second chance
            // for PCM_16-only HALs.
            let try_formats: &[ManagedPcmFormat] = if bit_perfect_route
                && !use_integer_format
                && sharing_mode == SharingMode::Exclusive
            {
                &[
                    ManagedPcmFormat::S32,
                    ManagedPcmFormat::S16,
                    ManagedPcmFormat::F32,
                ]
            } else {
                &[ManagedPcmFormat::F32]
            };
            for &attempt_fmt in try_formats {
                let result: Result<AndroidManagedStreamKind, String> = if use_integer_format {
                    let builder = oboe::AudioStreamBuilder::default()
                        .set_stereo()
                        .set_format::<i32>()
                        .set_sample_rate(target_sample_rate as i32)
                        .set_frames_per_callback(frames_per_callback)
                        .set_sharing_mode(sharing_mode)
                        .set_performance_mode(performance_mode)
                        .set_usage(Usage::Media)
                        .set_content_type(ContentType::Music)
                        .set_channel_conversion_allowed(false)
                        .set_format_conversion_allowed(false)
                        .set_sample_rate_conversion_quality(SampleRateConversionQuality::None)
                        .set_audio_api(audio_api);

                    let builder = if bit_perfect_route {
                        builder.set_device_id(selected_device.id)
                    } else {
                        builder
                    };

                    match builder
                        .set_callback(AndroidOutputCallbackI32::new(
                            Arc::clone(&callback_data),
                            event_tx.clone(),
                        ))
                        .open_stream()
                    {
                        Ok(stream) => Ok(AndroidManagedStreamKind::I32(stream)),
                        Err(error) => Err(format!(
                            "{} {} open failed on '{}' (id {}, type {:?}): {}",
                            audio_api_label(audio_api),
                            sharing_label(sharing_mode),
                            selected_device.product_name,
                            selected_device.id,
                            selected_device.device_type,
                            error
                        )),
                    }
                } else if attempt_fmt == ManagedPcmFormat::S32 {
                    // UAPP-style direct request: PCM_32 + DIRECT flag only.
                    // LowLatency tacks FAST onto the flags and breaks the
                    // direct_pcm profile match, so this attempt must keep
                    // PerformanceMode::None.
                    let builder = oboe::AudioStreamBuilder::default()
                        .set_stereo()
                        .set_format::<i32>()
                        .set_sample_rate(target_sample_rate as i32)
                        .set_frames_per_callback(frames_per_callback)
                        .set_sharing_mode(sharing_mode)
                        .set_performance_mode(PerformanceMode::None)
                        .set_usage(Usage::Media)
                        .set_content_type(ContentType::Music)
                        .set_channel_conversion_allowed(false)
                        .set_format_conversion_allowed(false)
                        .set_sample_rate_conversion_quality(SampleRateConversionQuality::None)
                        .set_audio_api(audio_api)
                        .set_device_id(selected_device.id);

                    match builder
                        .set_callback(AndroidOutputCallbackI32Pcm::new(
                            Arc::clone(&callback_data),
                            event_tx.clone(),
                        ))
                        .open_stream()
                    {
                        Ok(stream) => Ok(AndroidManagedStreamKind::I32Pcm(stream)),
                        Err(error) => Err(format!(
                            "{} {} pcm-i32 open failed on '{}' (id {}, type {:?}): {}",
                            audio_api_label(audio_api),
                            sharing_label(sharing_mode),
                            selected_device.product_name,
                            selected_device.id,
                            selected_device.device_type,
                            error
                        )),
                    }
                } else if attempt_fmt == ManagedPcmFormat::S16 {
                    let builder = oboe::AudioStreamBuilder::default()
                        .set_stereo()
                        .set_format::<i16>()
                        .set_sample_rate(target_sample_rate as i32)
                        .set_frames_per_callback(frames_per_callback)
                        .set_sharing_mode(sharing_mode)
                        .set_performance_mode(performance_mode)
                        .set_usage(Usage::Media)
                        .set_content_type(ContentType::Music)
                        .set_channel_conversion_allowed(false)
                        .set_format_conversion_allowed(false)
                        .set_sample_rate_conversion_quality(SampleRateConversionQuality::None)
                        .set_audio_api(audio_api)
                        .set_device_id(selected_device.id);

                    match builder
                        .set_callback(AndroidOutputCallbackI16::new(
                            Arc::clone(&callback_data),
                            event_tx.clone(),
                        ))
                        .open_stream()
                    {
                        Ok(stream) => Ok(AndroidManagedStreamKind::I16(stream)),
                        Err(error) => Err(format!(
                            "{} {} i16 open failed on '{}' (id {}, type {:?}): {}",
                            audio_api_label(audio_api),
                            sharing_label(sharing_mode),
                            selected_device.product_name,
                            selected_device.id,
                            selected_device.device_type,
                            error
                        )),
                    }
                } else {
                    let mut builder = oboe::AudioStreamBuilder::default()
                        .set_stereo()
                        .set_f32()
                        .set_sample_rate(target_sample_rate as i32)
                        .set_frames_per_callback(frames_per_callback)
                        .set_sharing_mode(sharing_mode)
                        .set_performance_mode(performance_mode)
                        .set_usage(Usage::Media)
                        .set_content_type(ContentType::Music)
                        .set_channel_conversion_allowed(false)
                        .set_format_conversion_allowed(true)
                        .set_sample_rate_conversion_quality(if bit_perfect_route {
                            SampleRateConversionQuality::None
                        } else {
                            SampleRateConversionQuality::Medium
                        })
                        .set_audio_api(audio_api);

                    if bit_perfect_route {
                        builder = builder.set_device_id(selected_device.id);
                    }

                    match builder
                        .set_callback(AndroidOutputCallbackF32::new(
                            Arc::clone(&callback_data),
                            event_tx.clone(),
                        ))
                        .open_stream()
                    {
                        Ok(stream) => Ok(AndroidManagedStreamKind::F32(stream)),
                        Err(error) => Err(format!(
                            "{} {} open failed on '{}' (id {}, type {:?}): {}",
                            audio_api_label(audio_api),
                            sharing_label(sharing_mode),
                            selected_device.product_name,
                            selected_device.id,
                            selected_device.device_type,
                            error
                        )),
                    }
                };

                match result {
                    Ok(kind) => {
                        let (actual_rate, actual_api, actual_sharing, actual_format, actual_channels) =
                            match &kind {
                                AndroidManagedStreamKind::F32(s) => (
                                    s.get_sample_rate(),
                                    s.get_audio_api(),
                                    s.get_sharing_mode(),
                                    s.get_format(),
                                    s.get_channel_count(),
                                ),
                                AndroidManagedStreamKind::I32(s) => (
                                    s.get_sample_rate(),
                                    s.get_audio_api(),
                                    s.get_sharing_mode(),
                                    s.get_format(),
                                    s.get_channel_count(),
                                ),
                                AndroidManagedStreamKind::I32Pcm(s) => (
                                    s.get_sample_rate(),
                                    s.get_audio_api(),
                                    s.get_sharing_mode(),
                                    s.get_format(),
                                    s.get_channel_count(),
                                ),
                                AndroidManagedStreamKind::I16(s) => (
                                    s.get_sample_rate(),
                                    s.get_audio_api(),
                                    s.get_sharing_mode(),
                                    s.get_format(),
                                    s.get_channel_count(),
                                ),
                            };

                        dev_eprintln!(
                        "Android managed output opened '{}' (id {}, type {:?}) requested {} Hz -> actual {} Hz, api {:?}, sharing {:?}, format {:?}, channels {:?}",
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

                        // A shared integer stream means the direct-PCM route
                        // was not granted; it would silently resample through
                        // the mixer like a shared f32 stream. Close it and
                        // keep looking (exclusive integer is the only prize).
                        if attempt_fmt != ManagedPcmFormat::F32
                            && sharing_label(actual_sharing) == "shared"
                        {
                            let note = format!(
                                "{} exclusive {} downgraded to shared on '{}' — not a direct-PCM route",
                                audio_api_label(audio_api),
                                attempt_fmt.label(),
                                selected_device.product_name,
                            );
                            last_error = Some(note.clone());
                            if sharing_mode == SharingMode::Exclusive {
                                exclusive_notes.push(note);
                            }
                            drop(kind);
                            continue;
                        }

                        if actual_channels != ChannelCount::Stereo {
                            last_error = Some(format!(
                                "{} {} opened '{}' with {:?} channels instead of {}",
                                audio_api_label(audio_api),
                                sharing_label(sharing_mode),
                                selected_device.product_name,
                                actual_channels,
                                ANDROID_DIRECT_CHANNELS,
                            ));
                            continue;
                        }

                        if bit_perfect_route && actual_rate != target_sample_rate as i32 {
                            last_error = Some(format!(
                                "{} {} opened '{}' at {} Hz instead of requested {} Hz",
                                audio_api_label(audio_api),
                                sharing_label(sharing_mode),
                                selected_device.product_name,
                                actual_rate,
                                target_sample_rate,
                            ));
                            if fallback_kind.is_none() {
                                fallback_format = Some(match &kind {
                                    AndroidManagedStreamKind::F32(_) => "f32",
                                    AndroidManagedStreamKind::I32(_) => "i32",
                                    AndroidManagedStreamKind::I32Pcm(_) => "s32",
                                    AndroidManagedStreamKind::I16(_) => "s16",
                                });
                                fallback_kind = Some(kind);
                                fallback_rate = actual_rate.max(1) as u32;
                                fallback_api = Some(audio_api_label(actual_api));
                                fallback_sharing = Some(sharing_label(actual_sharing));
                            }
                            continue;
                        }

                        let sample_format = match &kind {
                            AndroidManagedStreamKind::F32(_) => "f32",
                            AndroidManagedStreamKind::I32(_) => "i32",
                            AndroidManagedStreamKind::I32Pcm(_) => "s32",
                            AndroidManagedStreamKind::I16(_) => "s16",
                        };
                        let exclusive_error = if sharing_label(actual_sharing) == "exclusive" {
                            None
                        } else {
                            (!exclusive_notes.is_empty()).then(|| exclusive_notes.join(" | "))
                        };
                        return Ok(AndroidManagedStream {
                            kind,
                            actual_sample_rate: actual_rate.max(1) as u32,
                            active_audio_api: audio_api_label(actual_api),
                            active_sharing: sharing_label(actual_sharing),
                            sample_format,
                            exclusive_error,
                        });
                    }
                    Err(error) => {
                        if sharing_mode == SharingMode::Exclusive {
                            exclusive_notes.push(error.clone());
                        }
                        last_error = Some(error);
                        continue;
                    }
                }
            }
        }
    }

    if let Some(kind) = fallback_kind {
        return Ok(AndroidManagedStream {
            kind,
            actual_sample_rate: fallback_rate.max(1),
            active_audio_api: fallback_api.unwrap_or("Unspecified"),
            active_sharing: fallback_sharing.unwrap_or("Unspecified"),
            sample_format: fallback_format.unwrap_or("f32"),
            exclusive_error: (!exclusive_notes.is_empty()).then(|| exclusive_notes.join(" | ")),
        });
    }

    Err(last_error.unwrap_or_else(|| {
        format!(
            "No Android managed output stream could be opened for '{}' at {} Hz",
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
        dev_eprintln!(
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
fn android_device_supports_dap_native_strategy(device_type: AudioDeviceType) -> bool {
    matches!(
        device_type,
        AudioDeviceType::WiredHeadphones
            | AudioDeviceType::WiredHeadset
            | AudioDeviceType::LineAnalog
            | AudioDeviceType::LineDigital
    )
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
        AudioDeviceType::BuiltinSpeaker => 3,
        AudioDeviceType::BuiltinEarpiece => 4,
        AudioDeviceType::BuiltinSpeakerSafe => 5,
        _ => 6,
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

/// Resolve user audio-API preference to ordered Oboe candidates.
/// Bluetooth always uses Oboe's default — exclusive mode is wrong for the
/// mixer path. Explicit pref tried first, Unspecified as safety net.
#[cfg(target_os = "android")]
fn audio_api_attempts(pref: AudioApiPreference, is_bluetooth: bool) -> Vec<AudioApi> {
    if is_bluetooth {
        return vec![AudioApi::Unspecified];
    }
    match pref {
        AudioApiPreference::Auto | AudioApiPreference::AAudio => {
            vec![AudioApi::AAudio, AudioApi::Unspecified]
        }
        AudioApiPreference::OpenSLES => vec![AudioApi::OpenSLES, AudioApi::Unspecified],
    }
}

#[cfg(target_os = "android")]
fn sharing_label(sharing: SharingMode) -> &'static str {
    match sharing {
        SharingMode::Exclusive => "exclusive",
        SharingMode::Shared => "shared",
    }
}

/// Convert a linear volume slider value (0.0–1.0) to an exponential gain.
/// 1.0 → 0 dB, 0.0 → -∞ dB (silence). The slider position maps linearly to dB.
/// Exponent 2.0 gives a −40 dB range so 50 % slider → −20 dB (perceived ~¼ loudness).
///
/// Above 1.0 (extended volume) gain scales linearly to MAX_VOLUME (+6 dB at
/// 200 %), matching the Android LoudnessEnhancer mapping.
#[inline]
fn volume_to_gain(volume: f32) -> f32 {
    if volume <= 0.0 {
        0.0
    } else if volume <= 1.0 {
        10.0_f32.powf(2.0 * (volume - 1.0))
    } else {
        // Linear extension so 2.0 → 2.0 (+6.02 dB).
        volume.clamp(1.0, MAX_VOLUME)
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
    if data.is_paused() {
        data.fill_silence(output);
        return;
    }

    // Passthrough path: raw samples from decoder straight to output.
    if data.pipeline_mode.load(Ordering::Relaxed) == PipelineMode::Dop as u8 {
        let mut sources = match data.lock_sources_rt() {
            Some(s) => s,
            None => {
                data.dsd_lock_misses.fetch_add(1, Ordering::Relaxed);
                data.fill_silence(output);
                return;
            }
        };
        let (read, old_source) = sources.read(output);
        if let Some(source) = old_source {
            let _ = data.finished_tracks.try_send(source);
        }
        if read < output.len() {
            data.dsd_starved_samples
                .fetch_add((output.len() - read) as u64, Ordering::Relaxed);
            data.fill_silence(&mut output[read..]);
        }
        return;
    }

    // Passthrough: raw samples from decoder straight to output. Volume is
    // intentionally never applied here — bit-perfect means the DAC (UAC2
    // hardware volume) is the only volume authority. Software gain would
    // corrupt the stream.
    if data.is_passthrough() {
        let mut sources = match data.lock_sources_rt() {
            Some(s) => s,
            None => {
                data.dsd_lock_misses.fetch_add(1, Ordering::Relaxed);
                data.fill_silence(output);
                return;
            }
        };

        let (read, old_source) = sources.read(output);
        if let Some(source) = old_source {
            let _ = data.finished_tracks.try_send(source);
        }
        if read < output.len() {
            data.dsd_starved_samples
                .fetch_add((output.len() - read) as u64, Ordering::Relaxed);
            data.fill_silence(&mut output[read..]);
        }
        return;
    }

    // --- DSP path: full processing chain ---

    let volume = data.get_gain();
    let speed = data.get_playback_speed();
    let channels = data.channels();

    let mut sources = match data.sources.try_lock() {
        Some(s) => s,
        None => {
            output.fill(0.0);
            return;
        }
    };

    let mut crossfader = match data.crossfader.try_lock() {
        Some(c) => c,
        None => {
            let (read, old_source) = sources.read(output);

            if let Some(source) = old_source {
                let _ = data.finished_tracks.try_send(source);
            }

            if read < output.len() {
                output[read..].fill(0.0);
            }
            if let Some(mut pitch) = data.pitch_shifter.try_lock() {
                pitch.process(output, channels);
            }
            if let Some(mut eq) = data.equalizer.try_lock() {
                eq.process(output, channels);
            }
            if let Some(mut crossfeed) = data.crossfeed.try_lock() {
                crossfeed.process(output, channels);
            }
            if let Some(mut fx) = data.fx.try_lock() {
                fx.process(output, channels);
            }
            if let Some(mut convolver) = data.convolver.try_lock() {
                convolver.process(output, channels);
            }
            if let Some(mut dynamics) = data.dynamics.try_lock() {
                dynamics.process(output, channels);
            }
            // Volume is always applied last, after all DSP processing.
            for sample in output.iter_mut() {
                *sample *= volume;
            }
            return;
        }
    };

    if crossfader.is_active() && sources.next_mut().is_some() {
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

        let _ = crossfader.mix(&buf_a[..needed], &buf_b[..needed], output, channels);

        if !crossfader.is_active() {
            data.crossfade_active.store(false, Ordering::Relaxed);
            drop(crossfader);
            if let Some(source) = sources.advance_to_next() {
                let _ = data.finished_tracks.try_send(source);
            }
        }
    } else {
        if (speed - 1.0).abs() < 0.001 {
            let (read, old_source) = sources.read(output);

            if let Some(source) = old_source {
                let _ = data.finished_tracks.try_send(source);
            }

            if read < output.len() {
                output[read..].fill(0.0);
            }
        } else {
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
            let input_samples_needed =
                ((output_frames as f64 * speed as f64) + 2.0) as usize * channels;

            if speed_buf.len() < input_samples_needed {
                output.fill(0.0);
                return;
            }

            let (read, old_source) = sources.read(&mut speed_buf[..input_samples_needed]);

            if let Some(source) = old_source {
                let _ = data.finished_tracks.try_send(source);
            }

            if read < channels {
                output.fill(0.0);
                return;
            }

            let input_frames = read / channels;

            for out_frame in 0..output_frames {
                let in_pos = *frac_pos;
                let in_frame = in_pos as usize;
                let frac = (in_pos - in_frame as f64) as f32;

                if in_frame + 1 >= input_frames {
                    for ch in 0..channels {
                        output[out_frame * channels + ch] = 0.0;
                    }
                } else {
                    for ch in 0..channels {
                        let s0 = speed_buf[in_frame * channels + ch];
                        let s1 = speed_buf[(in_frame + 1) * channels + ch];
                        output[out_frame * channels + ch] = s0 + (s1 - s0) * frac;
                    }
                }

                *frac_pos += speed as f64;
            }

            let consumed_frames = (*frac_pos) as usize;
            *frac_pos -= consumed_frames as f64;
        }
    }

    if let Some(mut pitch) = data.pitch_shifter.try_lock() {
        pitch.process(output, channels);
    }
    if let Some(mut eq) = data.equalizer.try_lock() {
        eq.process(output, channels);
    }
    if let Some(mut crossfeed) = data.crossfeed.try_lock() {
        crossfeed.process(output, channels);
    }
    if let Some(mut fx) = data.fx.try_lock() {
        fx.process(output, channels);
    }
    if let Some(mut convolver) = data.convolver.try_lock() {
        convolver.process(output, channels);
    }
    if let Some(mut dynamics) = data.dynamics.try_lock() {
        dynamics.process(output, channels);
    }

    // Volume is always applied last, after all DSP processing.
    for sample in output.iter_mut() {
        *sample *= volume;
    }
}

/// Command processing loop running in the audio thread.
fn command_processing_loop(
    command_rx: Receiver<AudioCommand>,
    finished_rx: Receiver<AudioSource>,
    event_tx: Sender<AudioEvent>,
    callback_data: Arc<AudioCallbackData>,
    state: Arc<AtomicU8>,
    decoders: Arc<Mutex<Vec<DecoderHandle>>>,
    sample_rate: u32,
    shutdown: Arc<AtomicBool>,
    #[cfg_attr(not(target_os = "android"), allow(unused_mut, unused_variables))]
    mut supervisor: Option<&mut ManagedStreamSupervisor>,
) {
    loop {
        // Check shutdown flag
        if shutdown.load(Ordering::Acquire) {
            break;
        }

        // Reopen the Oboe stream if it was disconnected by an interruption
        // (audio focus loss, phone call, route change). The in-memory source
        // keeps its read position, so playback resumes exactly where it left
        // off instead of jumping to another time.
        #[cfg(target_os = "android")]
        if let Some(supervisor) = supervisor.as_mut() {
            supervisor.poll_restart(&shutdown);
        }

        // Check for finished tracks
        while let Ok(source) = finished_rx.try_recv() {
            let path = source.info.path.to_string_lossy().to_string();
            let _ = event_tx.try_send(AudioEvent::TrackEnded { path });

            // Crossfade completed — restore Playing state. This is the
            // natural bookend: a crossfade always ends with advance_to_next()
            // pushing the old source through finished_tracks.
            if state.load(Ordering::Relaxed) == PlaybackState::Crossfading as u8 {
                state.store(PlaybackState::Playing as u8, Ordering::Relaxed);
                let _ = event_tx.try_send(AudioEvent::StateChanged(PlaybackState::Playing));
            } else {
                // If no next source was queued for gapless transition,
                // the engine is outputting silence. Mark as stopped so
                // the Dart layer can detect the failure and fall back.
                let sources = callback_data.sources.lock();
                if sources.current().is_none() {
                    drop(sources);
                    state.store(PlaybackState::Stopped as u8, Ordering::Relaxed);
                    let _ = event_tx.try_send(AudioEvent::StateChanged(PlaybackState::Stopped));
                }
            }
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
                    AudioCommand::PlayPrepared {
                        source,
                        decoder_handle,
                    } => {
                        handle_play_prepared(
                            source,
                            decoder_handle,
                            &callback_data,
                            &state,
                            &decoders,
                            &event_tx,
                        );
                    }
                    AudioCommand::QueueNext { path } => {
                        handle_queue_next(path, &callback_data, &decoders, &event_tx, sample_rate);
                    }
                    AudioCommand::QueueNextPrepared {
                        source,
                        decoder_handle,
                    } => {
                        handle_queue_next_prepared(
                            source,
                            decoder_handle,
                            &callback_data,
                            &decoders,
                            &event_tx,
                        );
                    }
                    AudioCommand::Pause => {
                        // empty and state is already Stopped (see the track-ended
                        // handler above). Blindly flipping to Paused here leaves
                        // resume (audio_resume) silently "playing" nothing, which
                        // breaks resume after the queue ends. Skip the transition
                        // when there's no live source to pause.
                        let has_source = callback_data.sources.lock().current().is_some();
                        if has_source {
                            callback_data.set_paused(true);
                            state.store(PlaybackState::Paused as u8, Ordering::Relaxed);
                            let _ = event_tx
                                .try_send(AudioEvent::StateChanged(PlaybackState::Paused));
                        }
                    }
                    AudioCommand::Resume => {
                        callback_data.set_paused(false);
                        state.store(PlaybackState::Playing as u8, Ordering::Relaxed);
                        let _ = event_tx.try_send(AudioEvent::StateChanged(PlaybackState::Playing));
                    }
                    AudioCommand::Stop => {
                        callback_data.sources.lock().stop();
                        callback_data.crossfader.lock().reset();
                        callback_data.pitch_shifter.lock().reset();
                        callback_data.crossfade_active.store(false, Ordering::Relaxed);
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
                        // Drop pre-seek audio still sitting in the shifter.
                        callback_data.pitch_shifter.lock().reset();
                    }
                    AudioCommand::SetVolume { volume } => {
                        callback_data.set_volume(volume.clamp(0.0, MAX_VOLUME));
                    }
                    AudioCommand::SetReplayGain { gain_db } => {
                        // Store the default for spawns (next track, seek
                        // re-spawn), apply live to the current source so a
                        // settings change takes effect on the running track,
                        // and keep the callback out of bit-perfect passthrough
                        // whenever gain is non-neutral.
                        callback_data.set_replaygain_db(gain_db);
                        if let Some(current) = callback_data.sources.lock().current_mut() {
                            current.set_replaygain_db(gain_db);
                        }
                        log::info!(
                            "[replaygain] set gain_db={} forces_dsp={}",
                            gain_db,
                            gain_db != 0.0
                        );
                    }
                    AudioCommand::SetReplayGainDefault { gain_db } => {
                        // Pre-queueing the next gapless track: only the spawn
                        // default changes so the running track keeps its gain.
                        callback_data.set_replaygain_db(gain_db);
                    }
                    AudioCommand::SetCrossfade {
                        enabled,
                        duration_secs,
                    } => {
                        let mut crossfader = callback_data.crossfader.lock();
                        crossfader.set_enabled(enabled);
                        crossfader.set_duration(duration_secs);
                        let still_active = crossfader.is_active();
                        drop(crossfader);
                        callback_data
                            .crossfade_active
                            .store(still_active, Ordering::Relaxed);
                        // Crossfade needs the DSP path. Force out of passthrough
                        // when enabled so the mix runs even on a verified
                        // bit-perfect output (e.g. phone speaker at native rate).
                        callback_data
                            .crossfade_forces_dsp
                            .store(enabled, Ordering::Relaxed);
                        log::info!(
                            "[crossfade] set enabled={} duration={:.1}s forces_dsp={}",
                            enabled,
                            duration_secs,
                            enabled
                        );
                    }
                    AudioCommand::SetCrossfadeCurve { curve } => {
                        callback_data.crossfader.lock().set_curve(curve);
                    }
                    AudioCommand::SetPlaybackSpeed { speed } => {
                        callback_data.set_playback_speed(speed);
                        *callback_data.speed_frac_pos.lock() = 0.0;
                    }
                    AudioCommand::SetEqualizer { enabled, specs } => {
                        if let Some(mut eq) = callback_data.equalizer.try_lock() {
                            eq.set(enabled, &specs, sample_rate);
                        }
                        // EQ needs the DSP path (see crossfade). Force out of
                        // passthrough when active so the biquads run even on a
                        // verified bit-perfect USB output.
                        callback_data
                            .eq_forces_dsp
                            .store(enabled && !specs.is_empty(), Ordering::Relaxed);
                    }
                    AudioCommand::SetCrossfeed { level } => {
                        callback_data.crossfeed.lock().set_level(level);
                        // Crossfeed needs the DSP path (see EQ). Force out of
                        // passthrough when active so it runs even on a verified
                        // bit-perfect USB output.
                        callback_data
                            .crossfeed_forces_dsp
                            .store(level.is_active(), Ordering::Relaxed);
                        log::info!("[crossfeed] set level={level:?}");
                    }
                    AudioCommand::SetPitchShift { semitones } => {
                        log::info!("[PITCH] command handler: SetPitchShift({semitones})");
                        callback_data
                            .pitch_shifter
                            .lock()
                            .set_semitones(semitones);
                        // Pitch shift needs the DSP path (see crossfade).
                        callback_data
                            .pitch_shift_forces_dsp
                            .store(semitones != 0.0, Ordering::Relaxed);
                        log::info!("[PITCH] forces_dsp = {}", semitones != 0.0);
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
                    AudioCommand::SetPipelineMode { passthrough } => {
                        let mode = if passthrough {
                            PipelineMode::Passthrough
                        } else {
                            PipelineMode::Dsp
                        };
                        callback_data
                            .base_pipeline_mode
                            .store(mode as u8, Ordering::Relaxed);
                        // Keep an active DoP stream in DoP mode. The new base
                        // mode is restored when the raw override ends.
                        if callback_data.pipeline_mode.load(Ordering::Relaxed)
                            != PipelineMode::Dop as u8
                        {
                            callback_data.set_pipeline_mode(mode);
                        }
                    }
                    AudioCommand::SetDopOverride { is_dop } => {
                        if is_dop {
                            callback_data
                                .pipeline_mode
                                .store(PipelineMode::Dop as u8, Ordering::Relaxed);
                            callback_data.set_dop_wire_silence(true);
                        } else {
                            let base = callback_data.base_pipeline_mode.load(Ordering::Relaxed);
                            callback_data.pipeline_mode.store(base, Ordering::Relaxed);
                            callback_data.set_dop_wire_silence(false);
                        }
                    }
                    AudioCommand::SetFx {
                        enabled,
                        balance,
                        tempo,
                        damp,
                        filter_hz,
                        delay_ms,
                        size,
                        mix,
                        feedback,
                        width,
                    } => {
                        callback_data.fx.lock().set(
                            enabled, balance, tempo, damp, filter_hz, delay_ms, size, mix,
                            feedback, width,
                        );
                    }
                    AudioCommand::SetConvolver { enabled, mix } => {
                        callback_data.convolver.lock().set(enabled, mix);
                    }
                    AudioCommand::SetConvolverIr { coeffs } => {
                        callback_data.convolver.lock().load_ir(coeffs);
                    }
                    AudioCommand::ClearConvolverIr => {
                        callback_data.convolver.lock().clear_ir();
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

        // Auto-crossfade: start when the current track is near its end.
        // Both locks are held across the entire check+start to prevent the
        // audio callback from doing a hard gapless transition between the
        // remaining check and the crossfader.start() call.
        // Skipped entirely in passthrough (bit-perfect) and under 432 Hz
        // tuning (the mix bypasses speed resampling — see is_crossfade_allowed).
        if callback_data.is_crossfade_allowed() {
            // Fast path: if a crossfade is already in flight there is nothing
            // to trigger. Read the lock-free mirror so the real-time callback's
            // `crossfader` try_lock is never contended during the fade (a failed
            // try_lock drops the fade gains and emits the outgoing track at full
            // volume = audible chopping).
            if callback_data.crossfade_active.load(Ordering::Relaxed) {
                // Nothing to do; no locks taken.
            } else {
                let mut sources = callback_data.sources.lock();
                let mut crossfader = callback_data.crossfader.lock();
                let configured = crossfader.configured_duration_secs();
                if crossfader.is_enabled()
                    && !crossfader.is_active()
                    && sources.has_next()
                    && configured > 0.0
                {
                    if let Some(current) = sources.current() {
                        let remaining = current.remaining_secs();
                        // Clamp the fade to at most half the track so a short
                        // source does not have its start eaten by the fade-in.
                        let effective =
                            clamp_crossfade_secs(configured, current.info.duration_secs);
                        if effective > 0.0 && remaining > 0.0 && remaining <= effective as f64 {
                            // Only start crossfade if next track has buffered data.
                            // Require any data (≥0s) — the decoder has been running
                            // since the next track was pre-queued, so the buffer
                            // should be full by now.
                            if sources.next_has_enough_buffer(0.0) {
                                crossfader.set_active_duration_secs(effective);
                                crossfader.start();
                                callback_data
                                    .crossfade_active
                                    .store(true, Ordering::Relaxed);
                                state.store(
                                    PlaybackState::Crossfading as u8,
                                    Ordering::Relaxed,
                                );
                                let _ = event_tx.try_send(AudioEvent::StateChanged(
                                    PlaybackState::Crossfading,
                                ));
                                let from = sources
                                    .current()
                                    .map(|s| s.info.path.to_string_lossy().to_string());
                                let to = sources
                                    .next_mut()
                                    .map(|s| s.info.path.to_string_lossy().to_string());
                                if let (Some(from_path), Some(to_path)) = (from, to) {
                                    let _ = event_tx.try_send(AudioEvent::CrossfadeStarted {
                                        from_path,
                                        to_path,
                                    });
                                }
                            }
                        }
                    }
                }
            }
        }

        // Clean up finished decoders
        decoders.lock().retain(|d| d.is_running());
    }
}

fn spawn_decoder(
    path: PathBuf,
    sample_rate: u32,
    channels: usize,
    seek_secs: Option<f64>,
) -> anyhow::Result<(AudioSource, DecoderHandle)> {
    let file_type = detect_file_type(&path);
    match file_type {
        FileType::Dsd => {
            let requested = crate::api::audio_api::current_dsd_output_mode();
            let output_mode = crate::api::audio_api::effective_dsd_output_mode(requested);
            let (source, thread) = if let Some(seek) = seek_secs {
                DsdDecoderThread::spawn_with_seek(
                    path,
                    output_mode,
                    sample_rate,
                    channels,
                    Some(seek),
                )
            } else {
                DsdDecoderThread::spawn(path, output_mode, sample_rate, channels)
            }?;
            Ok((source, DecoderHandle::Dsd(thread)))
        }
        FileType::WavPack => {
            let (source, handle) = if let Some(seek) = seek_secs {
                WavpackDecoderThread::spawn_with_seek(path, sample_rate, channels, Some(seek))
            } else {
                WavpackDecoderThread::spawn(path, sample_rate, channels)
            }?;
            Ok((source, handle))
        }
        FileType::Standard => {
            let (source, thread) = if let Some(seek) = seek_secs {
                DecoderThread::spawn_with_seek(path, sample_rate, channels, Some(seek))
            } else {
                DecoderThread::spawn(path, sample_rate, channels)
            }?;
            Ok((source, DecoderHandle::Symphonia(thread)))
        }
    }
}

fn handle_play(
    path: PathBuf,
    callback_data: &AudioCallbackData,
    state: &Arc<AtomicU8>,
    decoders: &Arc<Mutex<Vec<DecoderHandle>>>,
    event_tx: &Sender<AudioEvent>,
    sample_rate: u32,
) {
    state.store(PlaybackState::Buffering as u8, Ordering::Relaxed);
    let _ = event_tx.try_send(AudioEvent::StateChanged(PlaybackState::Buffering));

    callback_data.sources.lock().stop();
    callback_data.crossfader.lock().reset();
    callback_data.crossfade_active.store(false, Ordering::Relaxed);

    match spawn_decoder(path.clone(), sample_rate, callback_data.channels(), None) {
        Ok((source, handle)) => {
            source.set_replaygain_db(callback_data.get_replaygain_db());
            start_playback_source(source, handle, callback_data, state, decoders, event_tx);
        }
        Err(e) => {
            let _ = event_tx.try_send(AudioEvent::Error {
                message: format!("Failed to decode {}: {}", path.display(), e),
            });
            state.store(PlaybackState::Idle as u8, Ordering::Relaxed);
        }
    }
}

fn handle_play_prepared(
    source: AudioSource,
    decoder_handle: DecoderHandle,
    callback_data: &AudioCallbackData,
    state: &Arc<AtomicU8>,
    decoders: &Arc<Mutex<Vec<DecoderHandle>>>,
    event_tx: &Sender<AudioEvent>,
) {
    state.store(PlaybackState::Buffering as u8, Ordering::Relaxed);
    let _ = event_tx.try_send(AudioEvent::StateChanged(PlaybackState::Buffering));

    source.set_replaygain_db(callback_data.get_replaygain_db());
    callback_data.sources.lock().stop();
    callback_data.crossfader.lock().reset();
    callback_data.crossfade_active.store(false, Ordering::Relaxed);

    start_playback_source(
        source,
        decoder_handle,
        callback_data,
        state,
        decoders,
        event_tx,
    );
}

fn handle_queue_next(
    path: PathBuf,
    callback_data: &AudioCallbackData,
    decoders: &Arc<Mutex<Vec<DecoderHandle>>>,
    event_tx: &Sender<AudioEvent>,
    sample_rate: u32,
) {
    match spawn_decoder(path.clone(), sample_rate, callback_data.channels(), None) {
        Ok((source, handle)) => {
            source.set_replaygain_db(callback_data.get_replaygain_db());
            queue_playback_source(source, handle, callback_data, decoders, event_tx);
        }
        Err(e) => {
            let _ = event_tx.try_send(AudioEvent::Error {
                message: format!("Failed to decode next track {}: {}", path.display(), e),
            });
        }
    }
}

fn handle_queue_next_prepared(
    source: AudioSource,
    decoder_handle: DecoderHandle,
    callback_data: &AudioCallbackData,
    decoders: &Arc<Mutex<Vec<DecoderHandle>>>,
    event_tx: &Sender<AudioEvent>,
) {
    source.set_replaygain_db(callback_data.get_replaygain_db());
    queue_playback_source(source, decoder_handle, callback_data, decoders, event_tx);
}

fn start_playback_source(
    mut source: AudioSource,
    decoder_handle: DecoderHandle,
    callback_data: &AudioCallbackData,
    state: &Arc<AtomicU8>,
    decoders: &Arc<Mutex<Vec<DecoderHandle>>>,
    event_tx: &Sender<AudioEvent>,
) {
    source.set_ready();
    source.set_playing();

    callback_data.sources.lock().set_current(source);
    callback_data.set_paused(false);
    decoders.lock().push(decoder_handle);

    state.store(PlaybackState::Playing as u8, Ordering::Relaxed);
    let _ = event_tx.try_send(AudioEvent::StateChanged(PlaybackState::Playing));
}

fn queue_playback_source(
    mut source: AudioSource,
    decoder_handle: DecoderHandle,
    callback_data: &AudioCallbackData,
    decoders: &Arc<Mutex<Vec<DecoderHandle>>>,
    event_tx: &Sender<AudioEvent>,
) {
    let queued_path = source.info.path.to_string_lossy().to_string();
    source.set_ready();

    callback_data.sources.lock().queue_next(source);
    decoders.lock().push(decoder_handle);

    let _ = event_tx.try_send(AudioEvent::NextTrackReady { path: queued_path });
}

/// Clamp the crossfade duration for a track of `track_total_secs`.
///
/// The fade is capped at half the track length so the fade-in never eats more
/// than the first half of a short source. Tracks whose duration is unknown
/// (`<= 0.0`) use the configured duration unchanged. The caller must skip
/// crossfade when the returned value is `<= 0.0` (only possible when
/// `configured` itself is `<= 0.0`).
fn clamp_crossfade_secs(configured: f32, track_total_secs: f64) -> f32 {
    if track_total_secs <= 0.0 {
        return configured;
    }
    let half = (track_total_secs * 0.5) as f32;
    configured.min(half)
}

fn handle_skip_to_next(
    callback_data: &AudioCallbackData,
    state: &Arc<AtomicU8>,
    event_tx: &Sender<AudioEvent>,
) {
    let mut sources = callback_data.sources.lock();
    let mut crossfader = callback_data.crossfader.lock();

    if !sources.has_next() {
        return;
    }

    // Manual skip crossfades when allowed (DSP path, no 432 Hz tuning) and the
    // fade length is sane for the incoming track; otherwise hard-cut.
    let started = if callback_data.is_crossfade_allowed()
        && crossfader.is_enabled()
        && !crossfader.is_active()
    {
        let configured = crossfader.configured_duration_secs();
        let next_total = sources.next().map(|s| s.info.duration_secs).unwrap_or(0.0);
        let effective = clamp_crossfade_secs(configured, next_total);
        if configured > 0.0 && effective > 0.0 {
            let from_path = sources
                .current()
                .map(|s| s.info.path.to_string_lossy().to_string());
            let to_path = sources
                .next_mut()
                .map(|s| s.info.path.to_string_lossy().to_string());
            crossfader.set_active_duration_secs(effective);
            crossfader.start();
            callback_data
                .crossfade_active
                .store(crossfader.is_active(), Ordering::Relaxed);
            state.store(PlaybackState::Crossfading as u8, Ordering::Relaxed);
            let _ = event_tx.try_send(AudioEvent::StateChanged(PlaybackState::Crossfading));
            if let (Some(from), Some(to)) = (from_path, to_path) {
                let _ = event_tx.try_send(AudioEvent::CrossfadeStarted {
                    from_path: from,
                    to_path: to,
                });
            }
            true
        } else {
            false
        }
    } else {
        false
    };

    if !started {
        // Immediate transition
        sources.advance_to_next();
        state.store(PlaybackState::Playing as u8, Ordering::Relaxed);
    }
}

fn handle_seek(
    position_secs: f64,
    callback_data: &AudioCallbackData,
    state: &Arc<AtomicU8>,
    decoders: &Arc<Mutex<Vec<DecoderHandle>>>,
    event_tx: &Sender<AudioEvent>,
    sample_rate: u32,
) {
    let target_secs = position_secs.max(0.0);

    let (path, http_origin, replaygain_db) = {
        let sources = callback_data.sources.lock();
        match sources.current() {
            Some(s) => (
                s.info.path.clone(),
                s.info.http_origin.clone(),
                s.replaygain_db(),
            ),
            None => (PathBuf::new(), None, 0.0),
        }
    };

    if path.as_os_str().is_empty() {
        let _ = event_tx.try_send(AudioEvent::Error {
            message: "Seek failed: no track loaded".to_string(),
        });
        return;
    }

    let was_paused = callback_data.is_paused();

    state.store(PlaybackState::Buffering as u8, Ordering::Relaxed);
    let _ = event_tx.try_send(AudioEvent::StateChanged(PlaybackState::Buffering));

    callback_data.sources.lock().stop();
    callback_data.crossfader.lock().reset();
    callback_data.crossfade_active.store(false, Ordering::Relaxed);
    *callback_data.speed_frac_pos.lock() = 0.0;

    {
        let mut active_decoders = decoders.lock();
        for decoder in active_decoders.drain(..) {
            decoder.stop();
        }
    }

    // HTTP sources (Jellyfin/Subsonic/WebDAV): SourceInfo.path is a URL label
    // with the auth query stripped, so spawn_decoder would try to open it as a
    // local file and fail -> engine Idle -> playback stuck. Re-probe the
    // ranged stream and spawn the decoder with a start position; decode_thread
    // then seeks the HttpMediaSource to the target byte range.
    let spawn_result = if let Some((url, headers)) = http_origin.as_ref() {
        match probe_http(url, headers.clone()) {
            Ok(probe_result) => DecoderThread::spawn_from_probe_result(
                probe_result,
                sample_rate,
                callback_data.channels(),
                Some(target_secs),
            )
            .map(|(s, h)| (s, DecoderHandle::Symphonia(h)))
            .map_err(|e| anyhow::anyhow!("{}", e)),
            Err(e) => Err(anyhow::anyhow!("{}", e)),
        }
    } else {
        spawn_decoder(
            path.clone(),
            sample_rate,
            callback_data.channels(),
            Some(target_secs),
        )
    };

    match spawn_result {
        Ok((mut source, handle)) => {
            source.set_replaygain_db(replaygain_db);
            source.set_ready();
            if !was_paused {
                source.set_playing();
            }

            callback_data.sources.lock().set_current(source);
            callback_data.set_paused(was_paused);
            decoders.lock().push(handle);

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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::source::{AudioSource, SourceInfo};
    use crossbeam_channel::bounded;
    use std::path::PathBuf;

    fn build_source(samples: &[f32], sample_rate: u32, channels: usize) -> AudioSource {
        let duration_secs = samples.len() as f64 / channels as f64 / sample_rate as f64;
        let info = SourceInfo {
            path: PathBuf::from("test.wav"),
            original_sample_rate: sample_rate,
            output_sample_rate: sample_rate,
            channels,
            total_samples: samples.len() as u64,
            duration_secs,
            http_origin: None,
        };
        let (mut source, mut producer) = AudioSource::new(info);

        assert_eq!(producer.write(samples), samples.len());
        producer.finish();
        source.set_ready();
        source.set_playing();
        source
    }

    fn build_callback_data(sample_rate: u32, channels: usize) -> AudioCallbackData {
        let (finished_tx, _finished_rx) = bounded::<AudioSource>(8);
        AudioCallbackData::new(sample_rate, channels, finished_tx, PipelineMode::Dsp)
    }

    fn build_passthrough_callback_data(sample_rate: u32, channels: usize) -> AudioCallbackData {
        let (finished_tx, _finished_rx) = bounded::<AudioSource>(8);
        AudioCallbackData::new(
            sample_rate,
            channels,
            finished_tx,
            PipelineMode::Passthrough,
        )
    }

    fn run_callback(data: &AudioCallbackData, output_len: usize) -> Vec<f32> {
        let (event_tx, _event_rx) = bounded::<AudioEvent>(8);
        let mut output = vec![123.0; output_len];
        audio_callback(&mut output, data, &event_tx);
        output
    }

    #[test]
    fn dsd_wire_silence_fills_with_silence_byte() {
        let data = build_passthrough_callback_data(705_600, 2);

        // DSD wire must get 0x69, not 0.0 (packs to DC = pop).
        data.set_dsd_wire_silence(true);
        let output = run_callback(&data, 16);
        assert!(output.iter().all(|s| (s.to_bits() & 0xFF) == 0x69));

        // PCM outputs keep true zero silence.
        data.set_dsd_wire_silence(false);
        let output = run_callback(&data, 16);
        assert!(output.iter().all(|s| s.to_bits() == 0));
    }

    #[test]
    fn callback_passthrough_ignores_volume() {
        let data = build_passthrough_callback_data(48_000, 2);
        let input = vec![0.0, 0.25, -0.5, 0.5, -0.25, 0.0, 1.0, -1.0];

        data.set_volume(0.25);
        data.sources
            .lock()
            .set_current(build_source(&input, 48_000, 2));

        let output = run_callback(&data, input.len());

        assert_eq!(output, input);
    }

    #[test]
    fn callback_applies_volume_after_switching_to_dsp() {
        let data = build_passthrough_callback_data(48_000, 2);
        let input = vec![0.5, -0.5, 0.25, -0.25];

        data.set_volume(0.25);
        data.set_pipeline_mode(PipelineMode::Dsp);
        data.sources
            .lock()
            .set_current(build_source(&input, 48_000, 2));

        let output = run_callback(&data, input.len());

        let gain = volume_to_gain(0.25);
        let expected: Vec<f32> = input.iter().map(|s| s * gain).collect();
        assert_eq!(output, expected);
    }

    #[test]
    fn callback_applies_source_replaygain_in_dsp() {
        let data = build_callback_data(48_000, 2);
        let input = vec![0.8, -0.8, 0.8, -0.8];

        let mut source = build_source(&input, 48_000, 2);
        source.set_replaygain_db(-6.0);
        data.sources.lock().set_current(source);

        let output = run_callback(&data, input.len());

        let expected = 0.8 * 10.0f32.powf(-0.3); // -6 dB ≈ 0.501×
        for (got, want) in output.iter().zip(&[0.8, -0.8, 0.8, -0.8]) {
            assert!((got - want * expected / 0.8).abs() < 1e-6, "got {got}");
        }
    }

    #[test]
    fn nonneutral_replaygain_forces_dsp_out_of_passthrough() {
        let data = build_passthrough_callback_data(48_000, 2);
        assert!(data.is_passthrough());

        data.set_replaygain_db(3.0);
        assert!(!data.is_passthrough());

        data.set_replaygain_db(0.0);
        assert!(data.is_passthrough());
    }

    #[test]
    fn active_crossfeed_forces_dsp_out_of_passthrough() {
        let data = build_passthrough_callback_data(48_000, 2);
        assert!(data.is_passthrough());

        data.crossfeed.lock().set_level(CrossfeedLevel::Default);
        data.crossfeed_forces_dsp
            .store(CrossfeedLevel::Default.is_active(), Ordering::Relaxed);
        assert!(!data.is_passthrough());

        data.crossfeed.lock().set_level(CrossfeedLevel::Off);
        data.crossfeed_forces_dsp
            .store(CrossfeedLevel::Off.is_active(), Ordering::Relaxed);
        assert!(data.is_passthrough());
    }

    #[test]
    fn callback_passthrough_zero_fills_tail_on_underrun() {
        let data = build_passthrough_callback_data(48_000, 2);
        let input = vec![0.5, -0.5, 0.25, -0.25];

        data.sources
            .lock()
            .set_current(build_source(&input, 48_000, 2));

        let output = run_callback(&data, 8);

        assert_eq!(output, vec![0.5, -0.5, 0.25, -0.25, 0.0, 0.0, 0.0, 0.0]);
    }

    #[test]
    fn callback_zero_fills_when_no_source_available() {
        let data = build_callback_data(48_000, 2);

        let output = run_callback(&data, 8);

        assert_eq!(output, vec![0.0; 8]);
    }

    #[test]
    fn callback_applies_gain_when_dsp() {
        let data = build_callback_data(48_000, 2);
        let input = vec![0.5, -0.5, 0.25, -0.25];

        data.set_volume(0.5);
        data.sources
            .lock()
            .set_current(build_source(&input, 48_000, 2));

        let output = run_callback(&data, input.len());

        let gain = volume_to_gain(0.5);
        let expected: Vec<f32> = input.iter().map(|s| s * gain).collect();
        assert_eq!(output, expected);
    }

    #[test]
    fn volume_to_gain_extended_range_is_linear_above_unity() {
        assert_eq!(volume_to_gain(1.0), 1.0);
        assert_eq!(volume_to_gain(1.5), 1.5);
        assert_eq!(volume_to_gain(2.0), 2.0);
        assert_eq!(volume_to_gain(5.0), 2.0);
        assert!(volume_to_gain(0.5) < 1.0);
    }

    #[test]
    fn audio_api_preference_str_round_trip() {
        for pref in [
            AudioApiPreference::Auto,
            AudioApiPreference::AAudio,
            AudioApiPreference::OpenSLES,
        ] {
            assert_eq!(AudioApiPreference::from_str(pref.as_str()), pref);
        }
        assert_eq!(AudioApiPreference::from_str("garbage"), AudioApiPreference::Auto);
    }

    #[cfg(target_os = "android")]
    #[test]
    fn audio_api_attempts_bluetooth_defers_to_oboe() {
        for pref in [
            AudioApiPreference::Auto,
            AudioApiPreference::AAudio,
            AudioApiPreference::OpenSLES,
        ] {
            assert_eq!(
                audio_api_attempts(pref, true),
                vec![AudioApi::Unspecified],
                "bluetooth must always use the Oboe default regardless of preference"
            );
        }
    }

    #[cfg(target_os = "android")]
    #[test]
    fn audio_api_attempts_wired_puts_preference_first() {
        assert_eq!(
            audio_api_attempts(AudioApiPreference::Auto, false),
            vec![AudioApi::AAudio, AudioApi::Unspecified]
        );
        assert_eq!(
            audio_api_attempts(AudioApiPreference::AAudio, false),
            vec![AudioApi::AAudio, AudioApi::Unspecified]
        );
        assert_eq!(
            audio_api_attempts(AudioApiPreference::OpenSLES, false),
            vec![AudioApi::OpenSLES, AudioApi::Unspecified]
        );
    }
}
