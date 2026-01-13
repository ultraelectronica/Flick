//! # Architecture
//!
//! The audio engine is designed with real-time audio constraints in mind:
//! - **No allocations** in the audio callback
//! - **Lock-free communication** between threads using ring buffers
//! - **Background decoding** to avoid I/O in the audio thread
//!
//! ## Components
//!
//! - `engine`: Core audio engine managing the output stream and mixing
//! - `decoder`: Background thread decoder using symphonia
//! - `resampler`: Sample rate conversion using rubato
//! - `crossfader`: Equal-power crossfade implementation
//! - `source`: Audio source abstraction for gapless playback

pub mod commands;
pub mod crossfader;
pub mod decoder;
pub mod engine;
pub mod resampler;
pub mod source;

pub use commands::{AudioCommand, PlaybackState};
pub use engine::{create_audio_engine, AudioEngineHandle};
