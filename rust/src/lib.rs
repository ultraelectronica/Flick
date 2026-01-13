pub mod api;

// Audio engine is only available on non-Android platforms due to C++ linking issues with cpal/oboe
#[cfg(not(target_os = "android"))]
pub mod audio;

mod frb_generated;
