//! UAC 2.0 device structure and management.

use crate::api::uac2_api::Uac2DeviceInfo;
use crate::uac2::capabilities::{CapabilityDetector, DeviceCapabilities};
use crate::uac2::error::Uac2Error;
use rusb::{Device, DeviceHandle, UsbContext};
use std::hash::{Hash, Hasher};

/// UAC 2.0 device representation.
/// Follows Single Responsibility Principle: only holds device information.
pub struct Uac2Device<T: UsbContext> {
    /// Device identification
    pub identification: DeviceIdentification,
    /// Device metadata
    pub metadata: DeviceMetadata,
    /// USB device handle (optional, only when device is opened)
    pub handle: Option<DeviceHandle<T>>,
    /// Device capabilities (placeholder for Phase 4)
    pub capabilities: DeviceCapabilities,
}

/// Device identification information.
#[derive(Debug, Clone)]
pub struct DeviceIdentification {
    /// USB vendor ID
    pub vendor_id: u16,
    /// USB product ID
    pub product_id: u16,
    /// Device serial number
    pub serial: Option<String>,
}

/// Device metadata information.
#[derive(Debug, Clone)]
pub struct DeviceMetadata {
    /// Product name
    pub product_name: String,
    /// Manufacturer name
    pub manufacturer: String,
}



impl<T: UsbContext> Uac2Device<T> {
    /// Creates a new UAC2 device from USB device.
    pub fn from_usb_device(device: &Device<T>) -> Result<Self, Uac2Error> {
        let device_desc = device.device_descriptor()?;
        let vendor_id = device_desc.vendor_id();
        let product_id = device_desc.product_id();

        let handle = device.open().ok();

        let (manufacturer, product_name, serial) = if let Some(ref h) = handle {
            (
                h.read_manufacturer_string_ascii(&device_desc)
                    .unwrap_or_default(),
                h.read_product_string_ascii(&device_desc)
                    .unwrap_or_else(|_| "USB Audio Device".to_string()),
                h.read_serial_number_string_ascii(&device_desc).ok(),
            )
        } else {
            (String::new(), "USB Audio Device".to_string(), None)
        };

        let capabilities = if let Some(ref h) = handle {
            CapabilityDetector::detect(device, h).unwrap_or_default()
        } else {
            DeviceCapabilities::default()
        };

        Ok(Self {
            identification: DeviceIdentification {
                vendor_id,
                product_id,
                serial,
            },
            metadata: DeviceMetadata {
                product_name,
                manufacturer,
            },
            handle,
            capabilities,
        })
    }

    /// Converts to FFI-compatible device info.
    pub fn to_device_info(&self) -> Uac2DeviceInfo {
        Uac2DeviceInfo {
            vendor_id: self.identification.vendor_id,
            product_id: self.identification.product_id,
            serial: self.identification.serial.clone(),
            product_name: self.metadata.product_name.clone(),
            manufacturer: self.metadata.manufacturer.clone(),
        }
    }

    pub fn capabilities(&self) -> &DeviceCapabilities {
        &self.capabilities
    }

    pub fn refresh_capabilities(&mut self, device: &Device<T>) -> Result<(), Uac2Error> {
        if let Some(ref handle) = self.handle {
            self.capabilities = CapabilityDetector::detect(device, handle)?;
        }
        Ok(())
    }
}

impl<T: UsbContext> PartialEq for Uac2Device<T> {
    fn eq(&self, other: &Self) -> bool {
        self.identification.vendor_id == other.identification.vendor_id
            && self.identification.product_id == other.identification.product_id
            && self.identification.serial == other.identification.serial
    }
}

impl<T: UsbContext> Eq for Uac2Device<T> {}

impl<T: UsbContext> Hash for Uac2Device<T> {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.identification.vendor_id.hash(state);
        self.identification.product_id.hash(state);
        self.identification.serial.hash(state);
    }
}

/// Trait for extracting device information.
pub trait DeviceInfo {
    /// Gets device identification.
    fn identification(&self) -> &DeviceIdentification;

    /// Gets device metadata.
    fn metadata(&self) -> &DeviceMetadata;

    /// Checks if device handle is available.
    fn has_handle(&self) -> bool;
}

impl<T: UsbContext> DeviceInfo for Uac2Device<T> {
    fn identification(&self) -> &DeviceIdentification {
        &self.identification
    }

    fn metadata(&self) -> &DeviceMetadata {
        &self.metadata
    }

    fn has_handle(&self) -> bool {
        self.handle.is_some()
    }
}
