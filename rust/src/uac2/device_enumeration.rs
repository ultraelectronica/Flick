use crate::api::uac2_api::Uac2DeviceInfo;
use crate::uac2::device::Uac2Device;
use crate::uac2::error::Uac2Error;
use rusb::{Context, Device, UsbContext};

const USB_CLASS_AUDIO: u8 = 0x01;
const USB_SUBCLASS_UAC2: u8 = 0x02;
const USB_PROTOCOL_UAC2: u8 = 0x20;

/// Enumerates UAC 2.0 devices.
pub fn enumerate_uac2_devices() -> Result<Vec<Uac2DeviceInfo>, Uac2Error> {
    let context = Context::new()?;
    let devices = context.devices()?;
    let mut out = Vec::new();

    for device in devices.iter() {
        if !is_uac2_audio_device(&device)? {
            continue;
        }

        match Uac2Device::from_usb_device(&device) {
            Ok(uac2_device) => {
                out.push(uac2_device.to_device_info());
            }
            Err(e) => {
                log::warn!("Failed to enumerate device: {}", e);
                // Continue with other devices
            }
        }
    }

    Ok(out)
}

/// Checks if device is UAC 2.0 audio device.
pub fn is_uac2_audio_device<T: UsbContext>(device: &Device<T>) -> Result<bool, Uac2Error> {
    let config = device.active_config_descriptor()?;

    for interface in config.interfaces() {
        for descriptor in interface.descriptors() {
            if descriptor.class_code() == USB_CLASS_AUDIO
                && descriptor.sub_class_code() == USB_SUBCLASS_UAC2
                && descriptor.protocol_code() == USB_PROTOCOL_UAC2
            {
                return Ok(true);
            }
        }
    }
    Ok(false)
}
