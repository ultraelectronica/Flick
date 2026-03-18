//! Error types for UAC 2.0 operations.

use thiserror::Error;

/// Errors that can occur during UAC 2.0 operations.
#[derive(Error, Debug)]
pub enum Uac2Error {
    /// USB device access error
    #[error("USB error: {0}")]
    Usb(#[from] rusb::Error),

    /// Device not found
    #[error("Device not found")]
    DeviceNotFound,

    /// Permission denied for USB device access
    #[error("Permission denied: {0}")]
    PermissionDenied(String),

    /// Device is busy or unavailable
    #[error("Device busy or unavailable: {0}")]
    DeviceBusy(String),

    /// Device handle not available
    #[error("Device handle not available")]
    NoHandle,

    /// Invalid device descriptor
    #[error("Invalid device descriptor: {0}")]
    InvalidDescriptor(String),

    /// Operation not supported
    #[error("Operation not supported: {0}")]
    NotSupported(String),
}

impl Uac2Error {
    /// Returns user-friendly error message
    pub fn user_message(&self) -> String {
        match self {
            Uac2Error::Usb(e) => format!("USB communication failed: {}", e),
            Uac2Error::DeviceNotFound => "USB Audio device not found".to_string(),
            Uac2Error::PermissionDenied(msg) => format!("Access denied: {}", msg),
            Uac2Error::DeviceBusy(msg) => format!("Device unavailable: {}", msg),
            Uac2Error::NoHandle => "Failed to open USB device".to_string(),
            Uac2Error::InvalidDescriptor(msg) => format!("Invalid device: {}", msg),
            Uac2Error::NotSupported(msg) => format!("Not supported: {}", msg),
        }
    }
}
