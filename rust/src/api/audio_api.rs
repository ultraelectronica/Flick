//! Flutter Rust Bridge API for audio engine control.
//!
//! This module provides the interface between Dart and the Rust audio engine.
//! Now available on all platforms including Android (using CPAL with Oboe backend).

use crate::audio::commands::{AudioEvent, PlaybackState};
use crate::audio::decoder::probe_file;
use crate::audio::engine::{create_audio_engine, desired_output_signature, AudioEngineHandle};
use once_cell::sync::Lazy;
use parking_lot::Mutex;
use std::path::PathBuf;

// Global audio engine handle
static AUDIO_ENGINE: Lazy<Mutex<Option<AudioEngineHandle>>> = Lazy::new(|| Mutex::new(None));

fn with_audio_engine<T>(
    f: impl FnOnce(&AudioEngineHandle) -> Result<T, String>,
) -> Result<T, String> {
    let guard = AUDIO_ENGINE.lock();
    let handle = guard
        .as_ref()
        .ok_or_else(|| "Audio engine not initialized".to_string())?;
    f(handle)
}

fn read_audio_engine<T>(f: impl FnOnce(&AudioEngineHandle) -> T) -> Option<T> {
    let guard = AUDIO_ENGINE.lock();
    guard.as_ref().map(f)
}

fn ensure_audio_engine(preferred_sample_rate: Option<u32>) -> Result<(), String> {
    let mut guard = AUDIO_ENGINE.lock();
    let desired_signature = desired_output_signature(preferred_sample_rate);
    let needs_recreate = match (guard.as_ref(), preferred_sample_rate) {
        (None, _) => true,
        (Some(handle), Some(rate)) => {
            handle.sample_rate() != rate || handle.output_signature() != desired_signature
        }
        (Some(handle), None) => handle.output_signature() != desired_signature,
    };

    if !needs_recreate {
        return Ok(());
    }

    if let Some(handle) = guard.take() {
        let _ = handle.shutdown();
    }

    *guard = Some(create_audio_engine(preferred_sample_rate)?);
    Ok(())
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
    ensure_audio_engine(None)
}

/// Check if the audio engine is initialized.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_is_initialized() -> bool {
    AUDIO_ENGINE.lock().is_some()
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
    let handle = AUDIO_ENGINE.lock().take();
    if let Some(handle) = handle {
        handle.shutdown()?;
    }
    Ok(())
}
