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

pub mod alac_converter;
pub mod backend;
pub mod commands;
pub mod convolver;
pub mod crossfeed;
pub mod crossfader;
pub mod decoder;
pub mod decoder_handle;
pub mod device;
pub mod dsd_alsa_direct;
pub mod dsd_engine;
pub mod dsd_sas_shim;
pub mod dsd_native_backend;
pub mod dsd_native_jni;
pub mod dynamics;
pub mod engine;
pub mod equalizer;
pub mod fx;
pub mod http_source;
pub mod ir_loader;
pub mod manager;
pub mod opus_decoder;
pub mod audiotrack_direct;
pub mod pitch_shifter;
pub mod resampler;
pub mod source;
pub mod strategy;
pub mod verifier;
pub mod wavpack_thread;

pub use alac_converter::{AudioMetadata, ConversionSession};
pub use backend::{AudioBackend, BackendDescriptor, BackendType};
pub use commands::{AudioCommand, PlaybackState};
pub use device::{dap_signatures, detect_dap, is_known_dap_model, DapSignature};
pub use engine::{create_audio_engine, AudioEngineHandle};
pub use manager::{AudioCapability, AudioCapabilitySnapshot, AudioEngine, EngineManager};
pub use strategy::{
    select_strategy, select_strategy_with_candidates, BackendCandidate, DeviceCaps, TrackInfo,
    DEFAULT_CANDIDATES,
};
