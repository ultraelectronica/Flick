//! Command definitions for audio engine control.
//!
//! Commands are sent from Dart through lock-free channels to avoid
//! blocking the audio thread.

use crate::audio::{decoder::DecoderThread, source::AudioSource};
use std::path::PathBuf;

/// Commands that can be sent to the audio engine.
pub enum AudioCommand {
    /// Load and play a track immediately
    Play { path: PathBuf },
    /// Load and play a track using a pre-probed decoder/source pair.
    PlayPrepared {
        source: AudioSource,
        decoder_thread: DecoderThread,
    },
    /// Queue a track for gapless playback (starts when current ends)
    QueueNext { path: PathBuf },
    /// Queue a track using a pre-probed decoder/source pair.
    QueueNextPrepared {
        source: AudioSource,
        decoder_thread: DecoderThread,
    },
    /// Pause playback (maintains position)
    Pause,
    /// Resume playback from paused position
    Resume,
    /// Stop playback completely and clear buffers
    Stop,
    /// Seek to a position in seconds
    Seek { position_secs: f64 },
    /// Set the main volume (0.0 to 1.0)
    SetVolume { volume: f32 },
    /// Enable/disable crossfade and set duration
    SetCrossfade { enabled: bool, duration_secs: f32 },
    /// Set playback speed (0.5 to 2.0)
    SetPlaybackSpeed { speed: f32 },
    /// Set graphic EQ: enabled and 10 band gains in dB.
    SetEqualizer { enabled: bool, gains_db: [f32; 10] },
    /// Configure compressor settings.
    SetCompressor {
        enabled: bool,
        threshold_db: f32,
        ratio: f32,
        attack_ms: f32,
        release_ms: f32,
        makeup_gain_db: f32,
    },
    /// Configure limiter settings.
    SetLimiter {
        enabled: bool,
        input_gain_db: f32,
        ceiling_db: f32,
        release_ms: f32,
    },
    /// Configure spatial/time FX settings.
    SetFx {
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
    TrackEnded { path: String },
    /// Crossfade started between tracks
    CrossfadeStarted { from_path: String, to_path: String },
    /// Error occurred during playback
    Error { message: String },
    /// Next track is ready (for gapless)
    NextTrackReady { path: String },
}
