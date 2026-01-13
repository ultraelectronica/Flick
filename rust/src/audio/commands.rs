//! Command definitions for audio engine control.
//!
//! Commands are sent from Dart through lock-free channels to avoid
//! blocking the audio thread.

use std::path::PathBuf;

/// Commands that can be sent to the audio engine.
#[derive(Debug, Clone)]
pub enum AudioCommand {
    /// Load and play a track immediately
    Play {
        path: PathBuf,
    },
    /// Queue a track for gapless playback (starts when current ends)
    QueueNext {
        path: PathBuf,
    },
    /// Pause playback (maintains position)
    Pause,
    /// Resume playback from paused position
    Resume,
    /// Stop playback completely and clear buffers
    Stop,
    /// Seek to a position in seconds
    Seek {
        position_secs: f64,
    },
    /// Set the main volume (0.0 to 1.0)
    SetVolume {
        volume: f32,
    },
    /// Enable/disable crossfade and set duration
    SetCrossfade {
        enabled: bool,
        duration_secs: f32,
    },
    /// Set playback speed (0.5 to 2.0)
    SetPlaybackSpeed {
        speed: f32,
    },
    /// Trigger crossfade to next track immediately
    CrossfadeToNext,
    /// Skip to the next track (with crossfade if enabled)
    SkipToNext,
    /// Shutdown the audio engine
    Shutdown,
}

/// Current playback state reported back to Dart.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlaybackState {
    /// Engine is idle, no track loaded
    Idle,
    /// Track is loaded and playing
    Playing,
    /// Playback is paused
    Paused,
    /// Currently buffering/loading
    Buffering,
    /// Crossfading between tracks
    Crossfading,
    /// Playback stopped (track ended or stop called)
    Stopped,
}

impl Default for PlaybackState {
    fn default() -> Self {
        Self::Idle
    }
}

/// Progress update sent to Dart via callbacks.
#[derive(Debug, Clone, Copy)]
pub struct PlaybackProgress {
    /// Current position in seconds
    pub position_secs: f64,
    /// Total duration in seconds (if known)
    pub duration_secs: Option<f64>,
    /// Current buffer fill level (0.0 to 1.0)
    pub buffer_level: f32,
}

/// Events emitted by the audio engine for Dart to handle.
#[derive(Debug, Clone)]
pub enum AudioEvent {
    /// Playback state changed
    StateChanged(PlaybackState),
    /// Progress update (sent periodically during playback)
    Progress(PlaybackProgress),
    /// Track finished naturally (not skipped)
    TrackEnded {
        path: String,
    },
    /// Crossfade started between tracks
    CrossfadeStarted {
        from_path: String,
        to_path: String,
    },
    /// Error occurred during playback
    Error {
        message: String,
    },
    /// Next track is ready (for gapless)
    NextTrackReady {
        path: String,
    },
}
