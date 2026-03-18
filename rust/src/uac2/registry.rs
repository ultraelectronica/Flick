//! Device registry for managing multiple UAC 2.0 devices.
//! Follows Open/Closed Principle: extensible without modification.

use crate::uac2::device::Uac2Device;
use crate::uac2::error::Uac2Error;
use rusb::{Context, UsbContext};
use std::collections::HashMap;
use std::hash::Hash;

/// Registry for managing multiple UAC 2.0 devices.
pub struct DeviceRegistry {
    /// USB context
    context: Context,
    /// Registered devices by device key
    devices: HashMap<DeviceKey, Uac2Device<Context>>,
}

/// Key for identifying devices in registry.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct DeviceKey {
    vendor_id: u16,
    product_id: u16,
    serial: Option<String>,
}

impl DeviceKey {
    /// Creates a device key from identification.
    pub fn from_identification(vendor_id: u16, product_id: u16, serial: Option<String>) -> Self {
        Self {
            vendor_id,
            product_id,
            serial,
        }
    }
}

impl DeviceRegistry {
    /// Creates a new device registry.
    pub fn new() -> Result<Self, Uac2Error> {
        Ok(Self {
            context: Context::new()?,
            devices: HashMap::new(),
        })
    }

    /// Refreshes the device list.
    pub fn refresh(&mut self) -> Result<(), Uac2Error> {
        self.devices.clear();
        let devices = self.context.devices()?;

        for device in devices.iter() {
            if crate::uac2::device_enumeration::is_uac2_audio_device(&device)? {
                match Uac2Device::from_usb_device(&device) {
                    Ok(uac2_device) => {
                        let key = DeviceKey::from_identification(
                            uac2_device.identification.vendor_id,
                            uac2_device.identification.product_id,
                            uac2_device.identification.serial.clone(),
                        );
                        self.devices.insert(key, uac2_device);
                    }
                    Err(e) => {
                        log::warn!("Failed to create device: {}", e);
                    }
                }
            }
        }

        Ok(())
    }

    /// Gets all registered devices.
    pub fn devices(&self) -> Vec<&Uac2Device<Context>> {
        self.devices.values().collect()
    }

    /// Gets device by key.
    pub fn get_device(&self, key: &DeviceKey) -> Option<&Uac2Device<Context>> {
        self.devices.get(key)
    }

    /// Removes device from registry.
    pub fn remove_device(&mut self, key: &DeviceKey) -> Option<Uac2Device<Context>> {
        self.devices.remove(key)
    }

    /// Clears all devices.
    pub fn clear(&mut self) {
        self.devices.clear();
    }
}

impl Default for DeviceRegistry {
    fn default() -> Self {
        Self::new().expect("Failed to create USB context")
    }
}
