//! Flutter Rust Bridge API for custom UAC 2.0 (USB Audio Class 2.0).
//!
//! This module provides the FFI between Dart and the Rust UAC2 implementation.
//! When the `uac2` feature is disabled, functions return stub values so the app
//! builds without USB dependencies.

// ============================================================================
// SHARED TYPES (available on all platforms, with or without `uac2` feature)
// ============================================================================

/// Information about a detected UAC 2.0 device (DAC/AMP).
#[derive(Debug, Clone)]
pub struct Uac2DeviceInfo {
    /// USB vendor ID
    pub vendor_id: u16,
    /// USB product ID
    pub product_id: u16,
    /// Device serial number (optional)
    pub serial: Option<String>,
    /// Product name string
    pub product_name: String,
    /// Manufacturer string
    pub manufacturer: String,
}

// ============================================================================
// API FUNCTIONS
// ============================================================================

/// Returns whether the UAC 2.0 backend is available on this build.
/// True when built with the `uac2` feature; false otherwise.
#[flutter_rust_bridge::frb(sync)]
pub fn uac2_is_available() -> bool {
    #[cfg(feature = "uac2")]
    {
        true
    }
    #[cfg(not(feature = "uac2"))]
    {
        false
    }
}

/// Enumerates connected UAC 2.0 devices.
/// Returns an empty list when the `uac2` feature is disabled or when no devices are found.
#[flutter_rust_bridge::frb(sync)]
pub fn uac2_list_devices() -> Result<Vec<Uac2DeviceInfo>, String> {
    #[cfg(feature = "uac2")]
    {
        // Phase 2 will implement real enumeration via rusb.
        // For Phase 1.2 bridge setup, return empty list.
        Ok(Vec::new())
    }
    #[cfg(not(feature = "uac2"))]
    {
        Ok(Vec::new())
    }
}
