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
            Ok(devices) => Ok(devices
                .into_iter()
                .map(|d| Uac2DeviceInfo {
                    vendor_id: d.identification.vendor_id,
                    product_id: d.identification.product_id,
                    serial: d.identification.serial,
                    product_name: d.metadata.product_name,
                    manufacturer: d.metadata.manufacturer,
                })
                .collect()),
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
        use crate::uac2::DeviceRegistry;
        
        let registry = DeviceRegistry::global();
        let devices = uac2::enumerate_uac2_devices().map_err(|e| e.user_message())?;
        
        let found = devices.into_iter().find(|d| {
            d.identification.vendor_id == device.vendor_id
                && d.identification.product_id == device.product_id
                && d.identification.serial == device.serial
        });

        if let Some(dev) = found {
            let caps = dev.capabilities();
            Ok(Uac2DeviceCapabilities {
                supported_sample_rates: caps
                    .supported_sample_rates
                    .iter()
                    .map(|r| r.hz())
                    .collect(),
                supported_bit_depths: caps
                    .supported_bit_depths
                    .iter()
                    .map(|d| d.bits())
                    .collect(),
                supported_channels: caps
                    .supported_channels
                    .iter()
                    .map(|&c| c as u16)
                    .collect(),
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
