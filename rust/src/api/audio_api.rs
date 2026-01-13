//! Flutter Rust Bridge API for audio engine control.
//!
//! This module provides the interface between Dart and the Rust audio engine.
//! On Android, the native audio engine is disabled due to C++ linking issues,
//! and all functions return appropriate error/stub values.

#[cfg(not(target_os = "android"))]
use crate::audio::commands::{AudioEvent, PlaybackState};
#[cfg(not(target_os = "android"))]
use crate::audio::engine::{create_audio_engine, AudioEngineHandle};
use once_cell::sync::OnceCell;
#[cfg(not(target_os = "android"))]
use std::path::PathBuf;

// Global audio engine handle (only used on non-Android platforms)
#[cfg(not(target_os = "android"))]
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
    StateChanged { state: String },
    Progress { position_secs: f64, duration_secs: Option<f64>, buffer_level: f32 },
    TrackEnded { path: String },
    CrossfadeStarted { from_path: String, to_path: String },
    Error { message: String },
    NextTrackReady { path: String },
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
    #[cfg(not(target_os = "android"))]
    { true }
    #[cfg(target_os = "android")]
    { false }
}

/// Initialize the audio engine.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_init() -> Result<(), String> {
    #[cfg(not(target_os = "android"))]
    {
        let handle = create_audio_engine()?;
        AUDIO_ENGINE
            .set(handle)
            .map_err(|_| "Audio engine already initialized".to_string())?;
        Ok(())
    }
    #[cfg(target_os = "android")]
    {
        Err("Native audio engine not available on Android".to_string())
    }
}

/// Check if the audio engine is initialized.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_is_initialized() -> bool {
    #[cfg(not(target_os = "android"))]
    { AUDIO_ENGINE.get().is_some() }
    #[cfg(target_os = "android")]
    { false }
}

/// Play an audio file.
pub fn audio_play(path: String) -> Result<(), String> {
    #[cfg(not(target_os = "android"))]
    {
        AUDIO_ENGINE
            .get()
            .ok_or("Audio engine not initialized")?
            .play(PathBuf::from(path))
    }
    #[cfg(target_os = "android")]
    {
        let _ = path;
        Err("Native audio not available on Android".to_string())
    }
}

/// Queue the next track for gapless playback.
pub fn audio_queue_next(path: String) -> Result<(), String> {
    #[cfg(not(target_os = "android"))]
    {
        AUDIO_ENGINE
            .get()
            .ok_or("Audio engine not initialized")?
            .queue_next(PathBuf::from(path))
    }
    #[cfg(target_os = "android")]
    {
        let _ = path;
        Err("Native audio not available on Android".to_string())
    }
}

/// Pause playback.
pub fn audio_pause() -> Result<(), String> {
    #[cfg(not(target_os = "android"))]
    {
        AUDIO_ENGINE
            .get()
            .ok_or("Audio engine not initialized")?
            .pause()
    }
    #[cfg(target_os = "android")]
    {
        Err("Native audio not available on Android".to_string())
    }
}

/// Resume playback after pause.
pub fn audio_resume() -> Result<(), String> {
    #[cfg(not(target_os = "android"))]
    {
        AUDIO_ENGINE
            .get()
            .ok_or("Audio engine not initialized")?
            .resume()
    }
    #[cfg(target_os = "android")]
    {
        Err("Native audio not available on Android".to_string())
    }
}

/// Stop playback completely.
pub fn audio_stop() -> Result<(), String> {
    #[cfg(not(target_os = "android"))]
    {
        AUDIO_ENGINE
            .get()
            .ok_or("Audio engine not initialized")?
            .stop()
    }
    #[cfg(target_os = "android")]
    {
        Err("Native audio not available on Android".to_string())
    }
}

/// Seek to a position in the current track.
pub fn audio_seek(position_secs: f64) -> Result<(), String> {
    #[cfg(not(target_os = "android"))]
    {
        AUDIO_ENGINE
            .get()
            .ok_or("Audio engine not initialized")?
            .seek(position_secs)
    }
    #[cfg(target_os = "android")]
    {
        let _ = position_secs;
        Err("Native audio not available on Android".to_string())
    }
}

/// Set the playback volume.
pub fn audio_set_volume(volume: f32) -> Result<(), String> {
    #[cfg(not(target_os = "android"))]
    {
        AUDIO_ENGINE
            .get()
            .ok_or("Audio engine not initialized")?
            .set_volume(volume)
    }
    #[cfg(target_os = "android")]
    {
        let _ = volume;
        Err("Native audio not available on Android".to_string())
    }
}

/// Configure crossfade settings.
pub fn audio_set_crossfade(enabled: bool, duration_secs: f32) -> Result<(), String> {
    #[cfg(not(target_os = "android"))]
    {
        AUDIO_ENGINE
            .get()
            .ok_or("Audio engine not initialized")?
            .set_crossfade(enabled, duration_secs)
    }
    #[cfg(target_os = "android")]
    {
        let _ = (enabled, duration_secs);
        Err("Native audio not available on Android".to_string())
    }
}

/// Skip to the next queued track.
pub fn audio_skip_to_next() -> Result<(), String> {
    #[cfg(not(target_os = "android"))]
    {
        AUDIO_ENGINE
            .get()
            .ok_or("Audio engine not initialized")?
            .skip_to_next()
    }
    #[cfg(target_os = "android")]
    {
        Err("Native audio not available on Android".to_string())
    }
}

/// Set the playback speed.
pub fn audio_set_playback_speed(speed: f32) -> Result<(), String> {
    #[cfg(not(target_os = "android"))]
    {
        AUDIO_ENGINE
            .get()
            .ok_or("Audio engine not initialized")?
            .set_playback_speed(speed)
    }
    #[cfg(target_os = "android")]
    {
        let _ = speed;
        Err("Native audio not available on Android".to_string())
    }
}

/// Get the current playback speed.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_get_playback_speed() -> Option<f32> {
    #[cfg(not(target_os = "android"))]
    { AUDIO_ENGINE.get().map(|h| h.get_playback_speed()) }
    #[cfg(target_os = "android")]
    { None }
}

/// Get the current playback state.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_get_state() -> String {
    #[cfg(not(target_os = "android"))]
    {
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
    #[cfg(target_os = "android")]
    {
        "unavailable".to_string()
    }
}

/// Get the current playback progress.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_get_progress() -> Option<AudioProgress> {
    #[cfg(not(target_os = "android"))]
    {
        AUDIO_ENGINE.get()?.get_progress().map(|p| AudioProgress {
            position_secs: p.position_secs,
            duration_secs: p.duration_secs,
            buffer_level: p.buffer_level,
        })
    }
    #[cfg(target_os = "android")]
    {
        None
    }
}

/// Poll for audio events (non-blocking).
#[flutter_rust_bridge::frb(sync)]
pub fn audio_poll_event() -> Option<AudioEventType> {
    #[cfg(not(target_os = "android"))]
    {
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
    #[cfg(target_os = "android")]
    {
        None
    }
}

/// Set the crossfade curve type.
pub fn audio_set_crossfade_curve(_curve: CrossfadeCurveType) -> Result<(), String> {
    Ok(())
}

/// Get the audio engine's sample rate.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_get_sample_rate() -> Option<u32> {
    #[cfg(not(target_os = "android"))]
    { AUDIO_ENGINE.get().map(|h| h.sample_rate()) }
    #[cfg(target_os = "android")]
    { None }
}

/// Get the number of audio channels.
#[flutter_rust_bridge::frb(sync)]
pub fn audio_get_channels() -> Option<usize> {
    #[cfg(not(target_os = "android"))]
    { AUDIO_ENGINE.get().map(|h| h.channels()) }
    #[cfg(target_os = "android")]
    { None }
}

/// Shutdown the audio engine.
pub fn audio_shutdown() -> Result<(), String> {
    #[cfg(not(target_os = "android"))]
    {
        if let Some(handle) = AUDIO_ENGINE.get() {
            handle.shutdown()?;
        }
        Ok(())
    }
    #[cfg(target_os = "android")]
    {
        Ok(())
    }
}
