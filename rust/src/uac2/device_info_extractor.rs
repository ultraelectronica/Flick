use crate::uac2::capabilities::{ControlCapabilities, PowerCapabilities};
use crate::uac2::constants::*;
use crate::uac2::descriptors::FeatureUnit;
use crate::uac2::error::Uac2Error;
use rusb::{DeviceHandle, UsbContext};

pub struct DeviceInfoExtractor;

impl DeviceInfoExtractor {
    pub fn extract_manufacturer<T: UsbContext>(
        handle: &DeviceHandle<T>,
        device_desc: &rusb::DeviceDescriptor,
    ) -> Result<String, Uac2Error> {
        handle
            .read_manufacturer_string_ascii(device_desc)
            .map_err(Uac2Error::from)
    }

    pub fn extract_product<T: UsbContext>(
        handle: &DeviceHandle<T>,
        device_desc: &rusb::DeviceDescriptor,
    ) -> Result<String, Uac2Error> {
        handle
            .read_product_string_ascii(device_desc)
            .map_err(Uac2Error::from)
    }

    pub fn extract_serial<T: UsbContext>(
        handle: &DeviceHandle<T>,
        device_desc: &rusb::DeviceDescriptor,
    ) -> Result<String, Uac2Error> {
        handle
            .read_serial_number_string_ascii(device_desc)
            .map_err(Uac2Error::from)
    }

    pub fn extract_power_info(_device_desc: &rusb::DeviceDescriptor) -> PowerCapabilities {
        PowerCapabilities {
            max_power_ma: 0,
            self_powered: false,
        }
    }

    pub fn extract_control_capabilities(
        feature_units: &[FeatureUnit],
    ) -> ControlCapabilities {
        let mut capabilities = ControlCapabilities {
            has_volume: false,
            has_mute: false,
            has_bass: false,
            has_treble: false,
            has_eq: false,
        };

        for fu in feature_units {
            for &control in &fu.bma_controls {
                if control & FEATURE_VOLUME != 0 {
                    capabilities.has_volume = true;
                }
                if control & FEATURE_MUTE != 0 {
                    capabilities.has_mute = true;
                }
                if control & FEATURE_BASS != 0 {
                    capabilities.has_bass = true;
                }
                if control & FEATURE_TREBLE != 0 {
                    capabilities.has_treble = true;
                }
                if control & FEATURE_GRAPHIC_EQ != 0 {
                    capabilities.has_eq = true;
                }
            }
        }

        capabilities
    }

    pub fn extract_control_ranges<T: UsbContext>(
        _handle: &DeviceHandle<T>,
        _feature_unit: &FeatureUnit,
    ) -> Result<Vec<(u32, u32, u32)>, Uac2Error> {
        Ok(Vec::new())
    }
}

pub struct StringDescriptorCache {
    manufacturer: Option<String>,
    product: Option<String>,
    serial: Option<String>,
}

impl StringDescriptorCache {
    pub fn new() -> Self {
        Self {
            manufacturer: None,
            product: None,
            serial: None,
        }
    }

    pub fn load<T: UsbContext>(
        &mut self,
        handle: &DeviceHandle<T>,
        device_desc: &rusb::DeviceDescriptor,
    ) {
        self.manufacturer = DeviceInfoExtractor::extract_manufacturer(handle, device_desc).ok();
        self.product = DeviceInfoExtractor::extract_product(handle, device_desc).ok();
        self.serial = DeviceInfoExtractor::extract_serial(handle, device_desc).ok();
    }

    pub fn manufacturer(&self) -> Option<&str> {
        self.manufacturer.as_deref()
    }

    pub fn product(&self) -> Option<&str> {
        self.product.as_deref()
    }

    pub fn serial(&self) -> Option<&str> {
        self.serial.as_deref()
    }
}

impl Default for StringDescriptorCache {
    fn default() -> Self {
        Self::new()
    }
}
