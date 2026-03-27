//! Flutter Rust Bridge API for audio engine control.
//!
//! This module provides the interface between Dart and the Rust audio engine.
//! Now available on all platforms including Android (using CPAL with Oboe backend).

use crate::audio::commands::{AudioEvent, PlaybackState};
use crate::audio::engine::{create_audio_engine, AudioEngineHandle};
use once_cell::sync::OnceCell;
use std::path::PathBuf;

// Global audio engine handle
static AUDIO_ENGINE: OnceCell<AudioEngineHandle> = OnceCell::new();

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
    let handle = create_audio_engine()?;
    AUDIO_ENGINE
        .set(handle)
        .map_err(|_| "Audio engine already initialized".to_string())?;
    Ok(())
}

/// Check if the audio engine is initialized.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_is_initialized() -> bool {
    AUDIO_ENGINE.get().is_some()
}

/// Play an audio file.
pub fn audio_play(path: String) -> Result<(), String> {
    AUDIO_ENGINE
        .get()
        .ok_or("Audio engine not initialized")?
        .play(PathBuf::from(path))
}

/// Queue the next track for gapless playback.
pub fn audio_queue_next(path: String) -> Result<(), String> {
    AUDIO_ENGINE
        .get()
        .ok_or("Audio engine not initialized")?
        .queue_next(PathBuf::from(path))
}

/// Pause playback.
pub fn audio_pause() -> Result<(), String> {
    AUDIO_ENGINE
        .get()
        .ok_or("Audio engine not initialized")?
        .pause()
}

/// Resume playback after pause.
pub fn audio_resume() -> Result<(), String> {
    AUDIO_ENGINE
        .get()
        .ok_or("Audio engine not initialized")?
        .resume()
}

/// Stop playback completely.
pub fn audio_stop() -> Result<(), String> {
    AUDIO_ENGINE
        .get()
        .ok_or("Audio engine not initialized")?
        .stop()
}

/// Seek to a position in the current track.
pub fn audio_seek(position_secs: f64) -> Result<(), String> {
    AUDIO_ENGINE
        .get()
        .ok_or("Audio engine not initialized")?
        .seek(position_secs)
}

/// Set the playback volume.
pub fn audio_set_volume(volume: f32) -> Result<(), String> {
    AUDIO_ENGINE
        .get()
        .ok_or("Audio engine not initialized")?
        .set_volume(volume)
}

/// Set graphic EQ: enabled and 10 band gains in dB (order = 32,64,125,250,500,1k,2k,4k,8k,16k Hz).
pub fn audio_set_equalizer(enabled: bool, gains_db: Vec<f32>) -> Result<(), String> {
    if gains_db.len() != 10 {
        return Err("Equalizer requires exactly 10 band gains".to_string());
    }
    let mut arr = [0.0f32; 10];
    arr.copy_from_slice(&gains_db[..10]);
    AUDIO_ENGINE
        .get()
        .ok_or("Audio engine not initialized")?
        .set_equalizer(enabled, arr)
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
    AUDIO_ENGINE
        .get()
        .ok_or("Audio engine not initialized")?
        .set_compressor(
            enabled,
            threshold_db,
            ratio,
            attack_ms,
            release_ms,
            makeup_gain_db,
        )
}

/// Configure limiter settings for the native audio engine.
pub fn audio_set_limiter(
    enabled: bool,
    input_gain_db: f32,
    ceiling_db: f32,
    release_ms: f32,
) -> Result<(), String> {
    AUDIO_ENGINE
        .get()
        .ok_or("Audio engine not initialized")?
        .set_limiter(enabled, input_gain_db, ceiling_db, release_ms)
}

/// Configure crossfade settings.
pub fn audio_set_crossfade(enabled: bool, duration_secs: f32) -> Result<(), String> {
    AUDIO_ENGINE
        .get()
        .ok_or("Audio engine not initialized")?
        .set_crossfade(enabled, duration_secs)
}

/// Skip to the next queued track.
pub fn audio_skip_to_next() -> Result<(), String> {
    AUDIO_ENGINE
        .get()
        .ok_or("Audio engine not initialized")?
        .skip_to_next()
}

/// Set the playback speed.
pub fn audio_set_playback_speed(speed: f32) -> Result<(), String> {
    AUDIO_ENGINE
        .get()
        .ok_or("Audio engine not initialized")?
        .set_playback_speed(speed)
}

/// Get the current playback speed.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_get_playback_speed() -> Option<f32> {
    AUDIO_ENGINE.get().map(|h| h.get_playback_speed())
}

/// Get the current playback state.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_get_state() -> String {
    let Some(handle) = AUDIO_ENGINE.get() else {
        return "uninitialized".to_string();
    };
    match handle.state() {
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
    AUDIO_ENGINE.get()?.get_progress().map(|p| AudioProgress {
        position_secs: p.position_secs,
        duration_secs: p.duration_secs,
        buffer_level: p.buffer_level,
    })
}

/// Poll for audio events (non-blocking).
#[flutter_rust_bridge::frb(sync)]
pub fn audio_poll_event() -> Option<AudioEventType> {
    let handle = AUDIO_ENGINE.get()?;
    let event = handle.try_recv_event()?;
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
    AUDIO_ENGINE.get().map(|h| h.sample_rate())
}

/// Get the current track path.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_get_current_path() -> Option<String> {
    AUDIO_ENGINE
        .get()
        .and_then(|h| h.get_current_path())
        .map(|p| p.to_string_lossy().to_string())
}

/// Get the number of audio channels.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_get_channels() -> Option<usize> {
    AUDIO_ENGINE.get().map(|h| h.channels())
}

/// Shutdown the audio engine.
pub fn audio_shutdown() -> Result<(), String> {
    if let Some(handle) = AUDIO_ENGINE.get() {
        handle.shutdown()?;
    }
    Ok(())
}
