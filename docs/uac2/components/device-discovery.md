# Device Discovery

Device discovery identifies and enumerates USB Audio Class 2.0 devices connected to the system.

## Overview

The discovery process filters USB devices by class, subclass, and protocol to identify UAC 2.0 compatible devices. It extracts device metadata and capabilities for use by the application.

## Key Components

### Device Enumeration

**Module:** `rust/src/uac2/device.rs`

Scans the USB bus for connected devices and filters by UAC 2.0 criteria:
- Class Code: `0x01` (Audio)
- Subclass: `0x02` (Audio Streaming)
- Protocol: `0x20` (UAC 2.0)

```rust
pub fn enumerate_devices() -> Result<Vec<Uac2Device>, Uac2Error> {
    // Enumerate all USB devices
    // Filter by UAC 2.0 class/subclass/protocol
    // Parse descriptors
    // Return device list
}
```

### Device Information

**Struct:** `Uac2Device`

Represents a discovered UAC 2.0 device with:
- Vendor ID (VID)
- Product ID (PID)
- Serial number
- Manufacturer name
- Product name
- Device capabilities

### Device Registry

**Module:** `rust/src/uac2/connection_manager.rs`

Maintains a registry of discovered devices:
- Tracks connected devices
- Handles device addition/removal
- Provides device lookup by ID
- Manages device lifecycle

## Discovery Process

1. **Enumerate USB Devices**
   - Query USB subsystem for all devices
   - Filter by device class

2. **Filter UAC 2.0 Devices**
   - Check class code (0x01)
   - Check subclass (0x02)
   - Check protocol (0x20)

3. **Extract Metadata**
   - Read string descriptors
   - Extract VID/PID
   - Get serial number

4. **Parse Descriptors**
   - Parse configuration descriptors
   - Parse interface descriptors
   - Parse endpoint descriptors

5. **Extract Capabilities**
   - Parse format descriptors
   - Extract supported sample rates
   - Identify channel configurations

6. **Register Device**
   - Add to device registry
   - Notify application
   - Update UI

## Hot-plug Support

The system monitors USB events for device connection and disconnection:

```rust
pub fn monitor_hotplug() -> Result<(), Uac2Error> {
    // Register hotplug callback
    // Handle device arrival
    // Handle device removal
}
```

### Device Arrival
- Enumerate new device
- Parse descriptors
- Register device
- Notify application

### Device Removal
- Stop active streams
- Unregister device
- Trigger fallback handler
- Notify application

## Device Filtering

Devices are filtered to ensure compatibility:

- Must support UAC 2.0 protocol
- Must have audio streaming interface
- Must have isochronous endpoints
- Must support PCM format (minimum)

## Error Handling

Common errors during discovery:

- **USB Permission Denied**: User must grant USB access
- **Device Busy**: Device in use by another application
- **Invalid Descriptors**: Malformed or unsupported descriptors
- **No Audio Interface**: Device lacks audio streaming interface

## Performance

Discovery is optimized for speed:
- Parallel descriptor parsing
- Cached device information
- Incremental updates on hot-plug
- Minimal USB bus queries

## Example Usage

```rust
// Enumerate devices
let devices = enumerate_devices()?;

// Filter by manufacturer
let my_dac = devices.iter()
    .find(|d| d.manufacturer.contains("MyDAC"));

// Get device capabilities
if let Some(dac) = my_dac {
    let caps = dac.capabilities();
    println!("Max sample rate: {}", caps.max_sample_rate);
}
```

## Platform Considerations

### Android
- Requires USB Host API
- User must grant USB permission
- Device filter in AndroidManifest.xml
- Permission dialog on device connection

### Linux
- Requires udev rules for non-root access
- libusb backend
- Hot-plug via udev events

## Related Components

- [Device Classification](device-discovery.md)
- [Descriptor Parsing](descriptors.md)
- [Capabilities](../api/rust-api.md#capabilities)
