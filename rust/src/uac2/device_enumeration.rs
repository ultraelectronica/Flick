use crate::uac2::device::Uac2Device;
use crate::uac2::error::Uac2Error;
use rusb::{Context, Device, UsbContext};
use tracing::{debug, info, warn};

const USB_CLASS_AUDIO: u8 = 0x01;
const USB_SUBCLASS_UAC2: u8 = 0x02;
const USB_PROTOCOL_UAC2: u8 = 0x20;

pub fn enumerate_uac2_devices() -> Result<Vec<Uac2Device<Context>>, Uac2Error> {
    info!("Starting UAC2 device enumeration");
    let context = Context::new()?;
    let devices = context.devices()?;
    let total_devices = devices.len();
    debug!(total_devices = total_devices, "USB devices found");

    let mut out = Vec::new();
    let mut uac2_count = 0;

    for device in devices.iter() {
        if !is_uac2_audio_device(&device)? {
            continue;
        }

        uac2_count += 1;
        debug!(device_index = uac2_count, "UAC2 device detected");

        match Uac2Device::from_usb_device(&device) {
            Ok(uac2_device) => {
                info!(
                    vendor_id = format!("{:04x}", uac2_device.identification.vendor_id),
                    product_id = format!("{:04x}", uac2_device.identification.product_id),
                    product_name = %uac2_device.metadata.product_name,
                    manufacturer = %uac2_device.metadata.manufacturer,
                    "UAC2 device enumerated successfully"
                );
                out.push(uac2_device);
            }
            Err(e) => {
                warn!(error = %e, "Failed to enumerate UAC2 device");
            }
        }
    }

    info!(
        total_devices = total_devices,
        uac2_devices = out.len(),
        "Device enumeration complete"
    );

    Ok(out)
}

pub fn is_uac2_audio_device<T: UsbContext>(device: &Device<T>) -> Result<bool, Uac2Error> {
    let config = device.active_config_descriptor()?;

    for interface in config.interfaces() {
        for descriptor in interface.descriptors() {
            if descriptor.class_code() == USB_CLASS_AUDIO
                && descriptor.sub_class_code() == USB_SUBCLASS_UAC2
                && descriptor.protocol_code() == USB_PROTOCOL_UAC2
            {
                debug!(
                    class = USB_CLASS_AUDIO,
                    subclass = USB_SUBCLASS_UAC2,
                    protocol = USB_PROTOCOL_UAC2,
                    "UAC2 audio device identified"
                );
                return Ok(true);
            }
        }
    }
    Ok(false)
}
