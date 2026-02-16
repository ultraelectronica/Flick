#[cfg(feature = "uac2")]
mod inner {
    use create::api::uac2_api::Uac2DeviceInfo;
    use rusb::{Context, Device, UsbContext};
    use std::time::Duration;

    const USB_CLASS_AUDIO: u8 = 0x01;
    const USB_SUBCLASS_UAC2: u8 = 0x02;
    const USB_PROTOCOL_UAC2: u8 = 0x20;

    const STRING_TIMEOUT: Duration = Duration::from_millis(100);

    pub fn enumerate_uac2_devices() -> Result<Vec<Uac2DeviceInfo>, rusb::Error> {
        let context = Context::new()?;
        let devices = context::devices()?;
        let mut out = Vec::new();

        for device in devices.iter() {
            if !is_uac2_audio_devices(&device)? {
                continue;
            }

            let device_desc = device.device_descriptor()?;
            let vendor_id = device_desc.vendor_id();
            let product_id = device_desc.product_id();

            let handle = match device.open() {
                Ok(h) => h,
                Err(_) => continue,
            };

            let manufacturer = handle
                .read_manufacturer_string_ascii(&device_desc, STRING_TIMEOUT)
                .unwrap_or_else(|_| String::new());

            let product_name = handle
                .read_product_string_ascii(&device_desc, STRING_TIMEOUT)
                .unwrap_or_else(|_| "USB Audio Device".to_string());

            let serial = handle
                .read_serial_number_string_ascii(&device_desc, STRING_TIMEOUT)
                .ok();

            out.push(Uac2DeviceInfo {
                vendor_id,
                product_id,
                serial,
                product_name,
                manufacturer,
            });
        }
        Ok(out)
    }

    fn is_uac2_audio_device<T: UsbContext>(device: &Device<T>) -> Result<bool, rusb::Error> {
        let config = device.active_config_descriptor()?;

        for interface in config.interfaces() {
            for descriptor in interface.descriptors() {
                if descriptor.class_code() == USB_CLASS_AUDIO
                    && descriptor.subclass_code() == USB_SUBCLASS_UAC2
                    && descriptor.protocol_code() == USB_PROTOCOL_UAC2
                {
                    return Ok(true);
                }
            }
        }
        Ok(false)
    }
}

#[cfg(feature = "uac2")]
pub use inner::enumerate_uac2_devices;
