# Flick Player

Music player featuring a custom UAC 2.0 implementation based on Rust.

## Features

- Custom USB Audio Class (UAC) 2.0 implementation
- High-performance Rust backend

## Platform setup (UAC 2.0)

### Android

UAC 2.0 DAC/AMP detection on Android uses the [USB Host API](https://developer.android.com/guide/topics/connectivity/usb/host).

- **Requirements:** Device must support USB host (OTG). The app declares `android.hardware.usb.host` as optional, so it installs on devices without USB host.
- **Permissions:** When a USB Audio Class 2.0 device is attached, the app can list it and request access. The user must grant permission when prompted. Use `Uac2Service.instance.requestPermission(deviceName)` (on Android, `deviceName` is in `Uac2DeviceInfo.serial` when the device has no serial string).
- **Device filter:** Only USB Audio Class 2.0 devices (class 0x01, subclass 0x02, protocol 0x20) are listed. Plugging in a UAC 2.0 DAC may open the app via the `USB_DEVICE_ATTACHED` intent.

Just wait for the next update. I am still making this. I'm not finished yet.