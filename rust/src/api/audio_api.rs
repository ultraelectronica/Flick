//! Flutter Rust Bridge API for audio engine control.
//!
//! This module provides the interface between Dart and the Rust audio engine.
//! Now available on all platforms including Android (using CPAL with Oboe backend).

use crate::audio::commands::{AudioEvent, PlaybackState};
use crate::audio::decoder::probe_file;
use crate::audio::manager::{AudioCapability, AudioCapabilitySnapshot, AudioEngine, EngineManager};
use once_cell::sync::Lazy;
use std::path::PathBuf;

static ENGINE_MANAGER: Lazy<EngineManager> = Lazy::new(EngineManager::new);

fn with_audio_engine<T>(
    f: impl FnOnce(&crate::audio::engine::AudioEngineHandle) -> Result<T, String>,
) -> Result<T, String> {
    ENGINE_MANAGER.with_rust_handle(f)
}

fn read_audio_engine<T>(
    f: impl FnOnce(&crate::audio::engine::AudioEngineHandle) -> T,
) -> Option<T> {
    ENGINE_MANAGER.read_rust_handle(f)
}

fn ensure_audio_engine(preferred_sample_rate: Option<u32>) -> Result<(), String> {
    ENGINE_MANAGER.ensure_rust_engine(preferred_sample_rate)
}

fn probe_output_sample_rate(path: &PathBuf) -> Option<u32> {
    probe_file(path.as_path())
        .map(|probe| probe.source_info.original_sample_rate)
        .ok()
}

// ============================================================================
// SHARED TYPES (available on all platforms)
// ============================================================================

/// Progress information returned to Dart.
#[derive(Debug, Clone)]
pub struct AudioProgress {
    /// Current position in seconds
    pub position_secs: f64,
    /// Total duration in seconds (if known)
    pub duration_secs: Option<f64>,
    /// Buffer fill level (0.0 to 1.0)
    pub buffer_level: f32,
}

/// Audio event types for Dart.
#[derive(Debug, Clone)]
pub enum AudioEventType {
    StateChanged {
        state: String,
    },
    Progress {
        position_secs: f64,
        duration_secs: Option<f64>,
        buffer_level: f32,
    },
    TrackEnded {
        path: String,
    },
    CrossfadeStarted {
        from_path: String,
        to_path: String,
    },
    Error {
        message: String,
    },
    NextTrackReady {
        path: String,
    },
}

/// Crossfade curve type for Dart.
#[derive(Debug, Clone, Copy)]
pub enum CrossfadeCurveType {
    EqualPower,
    Linear,
    SquareRoot,
    SCurve,
}

/// The currently available output capability classes for engine selection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AudioCapabilityType {
    UsbDac,
    HiResInternal,
    Standard,
}

impl From<AudioCapability> for AudioCapabilityType {
    fn from(value: AudioCapability) -> Self {
        match value {
            AudioCapability::UsbDac => Self::UsbDac,
            AudioCapability::HiResInternal => Self::HiResInternal,
            AudioCapability::Standard => Self::Standard,
        }
    }
}

impl From<AudioCapabilityType> for AudioCapability {
    fn from(value: AudioCapabilityType) -> Self {
        match value {
            AudioCapabilityType::UsbDac => Self::UsbDac,
            AudioCapabilityType::HiResInternal => Self::HiResInternal,
            AudioCapabilityType::Standard => Self::Standard,
        }
    }
}

#[derive(Debug, Clone)]
pub struct AudioCapabilityInfo {
    pub capabilities: Vec<AudioCapabilityType>,
    pub route_type: String,
    pub route_label: Option<String>,
    pub max_sample_rate: Option<u32>,
}

impl From<AudioCapabilitySnapshot> for AudioCapabilityInfo {
    fn from(value: AudioCapabilitySnapshot) -> Self {
        Self {
            capabilities: value.capabilities.into_iter().map(Into::into).collect(),
            route_type: value.route_type,
            route_label: value.route_label,
            max_sample_rate: value.max_sample_rate,
        }
    }
}

impl From<AudioCapabilityInfo> for AudioCapabilitySnapshot {
    fn from(value: AudioCapabilityInfo) -> Self {
        AudioCapabilitySnapshot {
            capabilities: value.capabilities.into_iter().map(Into::into).collect(),
            route_type: value.route_type,
            route_label: value.route_label,
            max_sample_rate: value.max_sample_rate,
        }
        .normalize()
    }
}

// ============================================================================
// API FUNCTIONS
// ============================================================================

/// Check if native audio is available on this platform.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_is_native_available() -> bool {
    // Native audio is now available on all platforms including Android
    true
}

/// Initialize the audio engine.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_init() -> Result<(), String> {
    ENGINE_MANAGER.init();
    Ok(())
}

/// Check if the audio engine is initialized.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_is_initialized() -> bool {
    ENGINE_MANAGER.is_rust_initialized()
}

/// Enable or disable high-res mode. When enabled, the Rust engine is allowed
/// to initialize even if a DAC is not currently detected.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_set_high_res_mode(enabled: bool) {
    ENGINE_MANAGER.set_high_res_mode(enabled);
}

/// Update the current platform capability snapshot used for engine selection.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_set_capability_info(info: AudioCapabilityInfo) {
    ENGINE_MANAGER.set_capability_snapshot(info.into());
}

/// Inspect the current capability snapshot after native detection and platform hints are merged.
pub fn audio_get_capability_info(
    preferred_sample_rate: Option<u32>,
) -> Result<AudioCapabilityInfo, String> {
    ENGINE_MANAGER
        .capability_snapshot(preferred_sample_rate)
        .map(Into::into)
}

/// Return the currently selected engine.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_get_active_engine() -> String {
    match ENGINE_MANAGER.current_engine() {
        Some(AudioEngine::Default) => "default".to_string(),
        Some(AudioEngine::Rust) => "rust".to_string(),
        None => "uninitialized".to_string(),
    }
}

/// Detect whether a DAC is present before attempting Rust engine initialization.
pub fn audio_is_dac_available(preferred_sample_rate: Option<u32>) -> Result<bool, String> {
    ENGINE_MANAGER.is_dac_available(preferred_sample_rate)
}

/// Play an audio file.
pub fn audio_play(path: String) -> Result<(), String> {
    let path = PathBuf::from(path);
    ensure_audio_engine(probe_output_sample_rate(&path))?;
    with_audio_engine(|handle| handle.play(path))
}

/// Queue the next track for gapless playback.
pub fn audio_queue_next(path: String) -> Result<(), String> {
    let path = PathBuf::from(path);
    if !audio_is_initialized() {
        ensure_audio_engine(probe_output_sample_rate(&path))?;
    }
    with_audio_engine(|handle| handle.queue_next(path))
}

/// Pause playback.
pub fn audio_pause() -> Result<(), String> {
    with_audio_engine(|handle| handle.pause())
}

/// Resume playback after pause.
pub fn audio_resume() -> Result<(), String> {
    with_audio_engine(|handle| handle.resume())
}

/// Stop playback completely.
pub fn audio_stop() -> Result<(), String> {
    with_audio_engine(|handle| handle.stop())
}

/// Seek to a position in the current track.
pub fn audio_seek(position_secs: f64) -> Result<(), String> {
    with_audio_engine(|handle| handle.seek(position_secs))
}

/// Set the playback volume.
pub fn audio_set_volume(volume: f32) -> Result<(), String> {
    with_audio_engine(|handle| handle.set_volume(volume))
}

/// Set graphic EQ: enabled and 10 band gains in dB (order = 32,64,125,250,500,1k,2k,4k,8k,16k Hz).
pub fn audio_set_equalizer(enabled: bool, gains_db: Vec<f32>) -> Result<(), String> {
    if gains_db.len() != 10 {
        return Err("Equalizer requires exactly 10 band gains".to_string());
    }
    let mut arr = [0.0f32; 10];
    arr.copy_from_slice(&gains_db[..10]);
    with_audio_engine(|handle| handle.set_equalizer(enabled, arr))
}

/// Configure compressor settings for the native audio engine.
pub fn audio_set_compressor(
    enabled: bool,
    threshold_db: f32,
    ratio: f32,
    attack_ms: f32,
    release_ms: f32,
    makeup_gain_db: f32,
) -> Result<(), String> {
    with_audio_engine(|handle| {
        handle.set_compressor(
            enabled,
            threshold_db,
            ratio,
            attack_ms,
            release_ms,
            makeup_gain_db,
        )
    })
}

/// Configure limiter settings for the native audio engine.
pub fn audio_set_limiter(
    enabled: bool,
    input_gain_db: f32,
    ceiling_db: f32,
    release_ms: f32,
) -> Result<(), String> {
    with_audio_engine(|handle| handle.set_limiter(enabled, input_gain_db, ceiling_db, release_ms))
}

/// Configure crossfade settings.
pub fn audio_set_crossfade(enabled: bool, duration_secs: f32) -> Result<(), String> {
    with_audio_engine(|handle| handle.set_crossfade(enabled, duration_secs))
}

/// Skip to the next queued track.
pub fn audio_skip_to_next() -> Result<(), String> {
    with_audio_engine(|handle| handle.skip_to_next())
}

/// Set the playback speed.
pub fn audio_set_playback_speed(speed: f32) -> Result<(), String> {
    with_audio_engine(|handle| handle.set_playback_speed(speed))
}

/// Get the current playback speed.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_get_playback_speed() -> Option<f32> {
    read_audio_engine(|handle| handle.get_playback_speed())
}

/// Get the current playback state.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_get_state() -> String {
    let Some(handle_state) = read_audio_engine(|handle| handle.state()) else {
        return "uninitialized".to_string();
    };
    match handle_state {
        PlaybackState::Idle => "idle".to_string(),
        PlaybackState::Playing => "playing".to_string(),
        PlaybackState::Paused => "paused".to_string(),
        PlaybackState::Buffering => "buffering".to_string(),
        PlaybackState::Crossfading => "crossfading".to_string(),
        PlaybackState::Stopped => "stopped".to_string(),
    }
}

/// Get the current playback progress.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_get_progress() -> Option<AudioProgress> {
    read_audio_engine(|handle| handle.get_progress())
        .flatten()
        .map(|p| AudioProgress {
            position_secs: p.position_secs,
            duration_secs: p.duration_secs,
            buffer_level: p.buffer_level,
        })
}

/// Poll for audio events (non-blocking).
#[flutter_rust_bridge::frb(sync)]
pub fn audio_poll_event() -> Option<AudioEventType> {
    let event = read_audio_engine(|handle| handle.try_recv_event()).flatten()?;
    Some(match event {
        AudioEvent::StateChanged(state) => AudioEventType::StateChanged {
            state: match state {
                PlaybackState::Idle => "idle".to_string(),
                PlaybackState::Playing => "playing".to_string(),
                PlaybackState::Paused => "paused".to_string(),
                PlaybackState::Buffering => "buffering".to_string(),
                PlaybackState::Crossfading => "crossfading".to_string(),
                PlaybackState::Stopped => "stopped".to_string(),
            },
        },
        AudioEvent::Progress(p) => AudioEventType::Progress {
            position_secs: p.position_secs,
            duration_secs: p.duration_secs,
            buffer_level: p.buffer_level,
        },
        AudioEvent::TrackEnded { path } => AudioEventType::TrackEnded { path },
        AudioEvent::CrossfadeStarted { from_path, to_path } => {
            AudioEventType::CrossfadeStarted { from_path, to_path }
        }
        AudioEvent::Error { message } => AudioEventType::Error { message },
        AudioEvent::NextTrackReady { path } => AudioEventType::NextTrackReady { path },
    })
}

/// Set the crossfade curve type.
pub fn audio_set_crossfade_curve(_curve: CrossfadeCurveType) -> Result<(), String> {
    Ok(())
}

/// Get the audio engine's sample rate.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_get_sample_rate() -> Option<u32> {
    read_audio_engine(|handle| handle.sample_rate())
}

/// Get the current track path.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_get_current_path() -> Option<String> {
    read_audio_engine(|handle| handle.get_current_path())
        .flatten()
        .map(|p| p.to_string_lossy().to_string())
}

/// Get the number of audio channels.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_get_channels() -> Option<usize> {
    read_audio_engine(|handle| handle.channels())
}

/// Shutdown the audio engine.
pub fn audio_shutdown() -> Result<(), String> {
    ENGINE_MANAGER.shutdown()
}
