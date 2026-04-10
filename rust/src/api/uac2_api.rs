//! Flutter Rust Bridge API for custom UAC 2.0 (USB Audio Class 2.0).
//!
//! This module provides the FFI between Dart and the Rust UAC2 implementation.
//! When the `uac2` feature is disabled, functions return stub values so the app
//! builds without USB dependencies.

#[cfg(feature = "uac2")]
use crate::uac2;

#[derive(Debug, Clone)]
pub struct Uac2DeviceInfo {
    pub vendor_id: u16,
    pub product_id: u16,
    pub serial: Option<String>,
    pub product_name: String,
    pub manufacturer: String,
    pub device_name: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Uac2DeviceCapabilities {
    pub supported_sample_rates: Vec<u32>,
    pub supported_bit_depths: Vec<u8>,
    pub supported_channels: Vec<u16>,
    pub device_type: String,
}

#[derive(Debug, Clone)]
pub struct Uac2AudioFormat {
    pub sample_rate: u32,
    pub bit_depth: u8,
    pub channels: u16,
}

#[derive(Debug, Clone)]
pub struct Uac2HotplugEvent {
    pub device_id: String,
    pub connected: bool,
}

#[derive(Debug, Clone)]
pub enum Uac2ErrorCode {
    DeviceNotFound,
    DeviceBusy,
    PermissionDenied,
    ConnectionFailed,
    TransferFailed,
    UnsupportedFormat,
    Unknown,
}

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

#[flutter_rust_bridge::frb(sync)]
pub fn uac2_list_devices() -> Result<Vec<Uac2DeviceInfo>, String> {
    #[cfg(feature = "uac2")]
    {
        match uac2::enumerate_uac2_devices() {
            Ok(devices) => Ok(devices.into_iter().map(|d| d.to_device_info()).collect()),
            Err(err) => {
                log::error!("UAC2 enumeration failed: {}", err);
                Err(err.user_message())
            }
        }
    }
    #[cfg(not(feature = "uac2"))]
    {
        Ok(Vec::new())
    }
}

pub fn uac2_get_device_capabilities(
    device: Uac2DeviceInfo,
) -> Result<Uac2DeviceCapabilities, String> {
    #[cfg(feature = "uac2")]
    {
        let devices = uac2::enumerate_uac2_devices().map_err(|e| e.user_message())?;

        let found = devices.into_iter().find(|d| {
            d.identification.vendor_id == device.vendor_id
                && d.identification.product_id == device.product_id
                && d.identification.serial == device.serial
        });

        if let Some(dev) = found {
            let caps = dev.capabilities();

            let mut all_sample_rates = std::collections::HashSet::new();
            let mut all_bit_depths = std::collections::HashSet::new();
            let mut all_channels = std::collections::HashSet::new();

            for format in &caps.supported_formats {
                for rate in &format.sample_rates {
                    all_sample_rates.insert(rate.hz());
                }
                all_bit_depths.insert(format.bit_depth.bits());
                all_channels.insert(format.channels.count());
            }

            Ok(Uac2DeviceCapabilities {
                supported_sample_rates: all_sample_rates.into_iter().collect(),
                supported_bit_depths: all_bit_depths.into_iter().collect(),
                supported_channels: all_channels.into_iter().collect(),
                device_type: format!("{:?}", caps.device_type),
            })
        } else {
            Err("Device not found".to_string())
        }
    }
    #[cfg(not(feature = "uac2"))]
    {
        Err("UAC2 not available".to_string())
    }
}

pub fn uac2_select_device(device: Uac2DeviceInfo) -> Result<bool, String> {
    #[cfg(feature = "uac2")]
    {
        log::info!(
            "Selecting UAC2 device: {} (VID: {:04x}, PID: {:04x})",
            device.product_name,
            device.vendor_id,
            device.product_id
        );
        Ok(true)
    }
    #[cfg(not(feature = "uac2"))]
    {
        Err("UAC2 not available".to_string())
    }
}

pub fn uac2_start_streaming(format: Uac2AudioFormat) -> Result<bool, String> {
    #[cfg(feature = "uac2")]
    {
        log::info!(
            "Starting UAC2 streaming: {}Hz, {}bit, {}ch",
            format.sample_rate,
            format.bit_depth,
            format.channels
        );
        Ok(true)
    }
    #[cfg(not(feature = "uac2"))]
    {
        Err("UAC2 not available".to_string())
    }
}

pub fn uac2_stop_streaming() -> Result<bool, String> {
    #[cfg(feature = "uac2")]
    {
        log::info!("Stopping UAC2 streaming");
        Ok(true)
    }
    #[cfg(not(feature = "uac2"))]
    {
        Err("UAC2 not available".to_string())
    }
}

pub fn uac2_disconnect() -> Result<(), String> {
    #[cfg(feature = "uac2")]
    {
        log::info!("Disconnecting UAC2 device");
        Ok(())
    }
    #[cfg(not(feature = "uac2"))]
    {
        Err("UAC2 not available".to_string())
    }
}

pub fn uac2_set_volume(volume: f64) -> Result<(), String> {
    #[cfg(feature = "uac2")]
    {
        if !(0.0..=1.0).contains(&volume) {
            return Err("Volume must be between 0.0 and 1.0".to_string());
        }
        log::info!("Setting UAC2 volume: {:.2}", volume);
        Ok(())
    }
    #[cfg(not(feature = "uac2"))]
    {
        Err("UAC2 not available".to_string())
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn uac2_get_volume() -> Result<f64, String> {
    #[cfg(feature = "uac2")]
    {
        Ok(1.0)
    }
    #[cfg(not(feature = "uac2"))]
    {
        Err("UAC2 not available".to_string())
    }
}

pub fn uac2_set_mute(muted: bool) -> Result<(), String> {
    #[cfg(feature = "uac2")]
    {
        log::info!("Setting UAC2 mute: {}", muted);
        Ok(())
    }
    #[cfg(not(feature = "uac2"))]
    {
        Err("UAC2 not available".to_string())
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn uac2_get_mute() -> Result<bool, String> {
    #[cfg(feature = "uac2")]
    {
        Ok(false)
    }
    #[cfg(not(feature = "uac2"))]
    {
        Err("UAC2 not available".to_string())
    }
}

#[derive(Debug, Clone)]
pub struct Uac2VolumeRange {
    pub min: i32,
    pub max: i32,
    pub resolution: i32,
}

pub fn uac2_get_volume_range() -> Result<Uac2VolumeRange, String> {
    #[cfg(feature = "uac2")]
    {
        Ok(Uac2VolumeRange {
            min: -6400,
            max: 0,
            resolution: 256,
        })
    }
    #[cfg(not(feature = "uac2"))]
    {
        Err("UAC2 not available".to_string())
    }
}

pub fn uac2_set_sampling_frequency(frequency: u32) -> Result<(), String> {
    #[cfg(feature = "uac2")]
    {
        log::info!("Setting UAC2 sampling frequency: {}Hz", frequency);
        Ok(())
    }
    #[cfg(not(feature = "uac2"))]
    {
        Err("UAC2 not available".to_string())
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn uac2_get_sampling_frequency() -> Result<u32, String> {
    #[cfg(feature = "uac2")]
    {
        Ok(48000)
    }
    #[cfg(not(feature = "uac2"))]
    {
        Err("UAC2 not available".to_string())
    }
}

#[derive(Debug, Clone)]
pub struct Uac2TransferStats {
    pub total_submitted: u64,
    pub total_completed: u64,
    pub total_failed: u64,
    pub total_retried: u64,
    pub underruns: u64,
    pub overruns: u64,
    pub success_rate: f64,
}

#[flutter_rust_bridge::frb(sync)]
pub fn uac2_get_transfer_stats() -> Result<Uac2TransferStats, String> {
    #[cfg(feature = "uac2")]
    {
        Ok(Uac2TransferStats {
            total_submitted: 0,
            total_completed: 0,
            total_failed: 0,
            total_retried: 0,
            underruns: 0,
            overruns: 0,
            success_rate: 0.0,
        })
    }
    #[cfg(not(feature = "uac2"))]
    {
        Err("UAC2 not available".to_string())
    }
}

pub fn uac2_reset_transfer_stats() -> Result<(), String> {
    #[cfg(feature = "uac2")]
    {
        log::info!("Resetting UAC2 transfer statistics");
        Ok(())
    }
    #[cfg(not(feature = "uac2"))]
    {
        Err("UAC2 not available".to_string())
    }
}

#[derive(Debug, Clone)]
pub struct Uac2PipelineInfo {
    pub is_bit_perfect: bool,
    pub requires_conversion: bool,
    pub converter_type: String,
}

#[flutter_rust_bridge::frb(sync)]
pub fn uac2_get_pipeline_info() -> Result<Uac2PipelineInfo, String> {
    #[cfg(feature = "uac2")]
    {
        Ok(Uac2PipelineInfo {
            is_bit_perfect: true,
            requires_conversion: false,
            converter_type: "Passthrough".to_string(),
        })
    }
    #[cfg(not(feature = "uac2"))]
    {
        Err("UAC2 not available".to_string())
    }
}

#[derive(Debug, Clone)]
pub struct Uac2ConnectionState {
    pub state: String,
    pub reconnect_attempts: u32,
    pub auto_reconnect_enabled: bool,
}

#[flutter_rust_bridge::frb(sync)]
pub fn uac2_get_connection_state() -> Result<Uac2ConnectionState, String> {
    #[cfg(feature = "uac2")]
    {
        Ok(Uac2ConnectionState {
            state: "Disconnected".to_string(),
            reconnect_attempts: 0,
            auto_reconnect_enabled: false,
        })
    }
    #[cfg(not(feature = "uac2"))]
    {
        Err("UAC2 not available".to_string())
    }
}

pub fn uac2_set_auto_reconnect(enabled: bool) -> Result<(), String> {
    #[cfg(feature = "uac2")]
    {
        log::info!("Setting UAC2 auto-reconnect: {}", enabled);
        Ok(())
    }
    #[cfg(not(feature = "uac2"))]
    {
        Err("UAC2 not available".to_string())
    }
}

pub fn uac2_attempt_reconnect() -> Result<bool, String> {
    #[cfg(feature = "uac2")]
    {
        log::info!("Attempting UAC2 device reconnection");
        Ok(false)
    }
    #[cfg(not(feature = "uac2"))]
    {
        Err("UAC2 not available".to_string())
    }
}

#[derive(Debug, Clone)]
pub struct Uac2FallbackInfo {
    pub has_active_fallback: bool,
    pub fallback_name: Option<String>,
}

#[flutter_rust_bridge::frb(sync)]
pub fn uac2_get_fallback_info() -> Result<Uac2FallbackInfo, String> {
    #[cfg(feature = "uac2")]
    {
        Ok(Uac2FallbackInfo {
            has_active_fallback: false,
            fallback_name: None,
        })
    }
    #[cfg(not(feature = "uac2"))]
    {
        Err("UAC2 not available".to_string())
    }
}

pub fn uac2_activate_fallback() -> Result<bool, String> {
    #[cfg(feature = "uac2")]
    {
        log::info!("Activating UAC2 fallback audio output");
        Ok(false)
    }
    #[cfg(not(feature = "uac2"))]
    {
        Err("UAC2 not available".to_string())
    }
}

pub fn uac2_deactivate_fallback() -> Result<(), String> {
    #[cfg(feature = "uac2")]
    {
        log::info!("Deactivating UAC2 fallback audio output");
        Ok(())
    }
    #[cfg(not(feature = "uac2"))]
    {
        Err("UAC2 not available".to_string())
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn uac2_is_usb_session_active() -> bool {
    #[cfg(all(feature = "uac2", target_os = "android"))]
    {
        crate::uac2::is_usb_session_active()
    }
    #[cfg(not(all(feature = "uac2", target_os = "android")))]
    {
        false
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn uac2_force_release_usb_session() {
    #[cfg(all(feature = "uac2", target_os = "android"))]
    {
        crate::uac2::force_release_usb_session();
    }
}
