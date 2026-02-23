//! Custom USB Audio Class 2.0 (UAC 2.0) support for DAC/AMP detection and bit-perfect playback.

#[cfg(feature = "uac2")]
mod device_enumeration;
#[cfg(feature = "uac2")]
mod device;
#[cfg(feature = "uac2")]
mod registry;
#[cfg(feature = "uac2")]
mod error;

#[cfg(feature = "uac2")]
pub use device_enumeration::enumerate_uac2_devices;
#[cfg(feature = "uac2")]
pub use error::Uac2Error;
#[cfg(feature = "uac2")]
pub use device::{Uac2Device, DeviceInfo, DeviceIdentification, DeviceMetadata};
#[cfg(feature = "uac2")]
pub use registry::{DeviceRegistry, DeviceKey};
