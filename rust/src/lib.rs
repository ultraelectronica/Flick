pub mod api;

// Audio engine is only available on non-Android platforms due to C++ linking issues with cpal/oboe
#[cfg(not(target_os = "android"))]
pub mod audio;

/// Custom UAC 2.0 USB Audio (DAC/AMP detection and bit-perfect playback).
/// Real implementation is gated by the `uac2` feature.
pub mod uac2;

mod frb_generated;
