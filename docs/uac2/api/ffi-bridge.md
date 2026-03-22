# FFI Bridge

The FFI bridge connects Rust and Flutter using `flutter_rust_bridge`.

## Overview

The bridge provides:
- Type-safe communication between Rust and Dart
- Automatic code generation
- Async/await support
- Error propagation
- Stream support

## Bridge Architecture

```
Flutter (Dart)
     │
     │ Dart API
     ▼
┌─────────────────┐
│ Generated       │
│ Dart Bindings   │
└────────┬────────┘
         │ FFI
         ▼
┌─────────────────┐
│ Generated       │
│ Rust Bindings   │
└────────┬────────┘
         │ Rust API
         ▼
Rust Implementation
```

## Bridge Definition

**Location:** `rust/src/api/audio_api.rs`

### Device Operations

```rust
#[flutter_rust_bridge::frb(sync)]
pub fn uac2_enumerate_devices() -> Result<Vec<Uac2DeviceInfoFfi>, Uac2ErrorFfi> {
    // Implementation
}

#[flutter_rust_bridge::frb(sync)]
pub fn uac2_connect_device(device_id: String) -> Result<(), Uac2ErrorFfi> {
    // Implementation
}

#[flutter_rust_bridge::frb(sync)]
pub fn uac2_disconnect_device() -> Result<(), Uac2ErrorFfi> {
    // Implementation
}

#[flutter_rust_bridge::frb(sync)]
pub fn uac2_get_capabilities(device_id: String) -> Result<Uac2CapabilitiesFfi, Uac2ErrorFfi> {
    // Implementation
}
```

### Streaming Operations

```rust
#[flutter_rust_bridge::frb(sync)]
pub fn uac2_start_stream(config: Uac2StreamConfigFfi) -> Result<(), Uac2ErrorFfi> {
    // Implementation
}

#[flutter_rust_bridge::frb(sync)]
pub fn uac2_stop_stream() -> Result<(), Uac2ErrorFfi> {
    // Implementation
}
```

### Control Operations

```rust
#[flutter_rust_bridge::frb(sync)]
pub fn uac2_set_volume(volume: f32) -> Result<(), Uac2ErrorFfi> {
    // Implementation
}

#[flutter_rust_bridge::frb(sync)]
pub fn uac2_get_volume() -> Result<f32, Uac2ErrorFfi> {
    // Implementation
}

#[flutter_rust_bridge::frb(sync)]
pub fn uac2_set_mute(muted: bool) -> Result<(), Uac2ErrorFfi> {
    // Implementation
}

#[flutter_rust_bridge::frb(sync)]
pub fn uac2_get_mute() -> Result<bool, Uac2ErrorFfi> {
    // Implementation
}
```

### Event Streams

```rust
pub fn uac2_state_stream() -> impl Stream<Item = Uac2StateFfi> {
    // Implementation
}

pub fn uac2_hotplug_stream() -> impl Stream<Item = Uac2HotplugEventFfi> {
    // Implementation
}
```

## FFI Types

### Uac2DeviceInfoFfi

```rust
#[derive(Clone, Debug)]
pub struct Uac2DeviceInfoFfi {
    pub id: String,
    pub vendor_id: u16,
    pub product_id: u16,
    pub manufacturer: String,
    pub product: String,
    pub serial: String,
    pub capabilities: Uac2CapabilitiesFfi,
}
```

### Uac2CapabilitiesFfi

```rust
#[derive(Clone, Debug)]
pub struct Uac2CapabilitiesFfi {
    pub supported_formats: Vec<Uac2AudioFormatFfi>,
    pub max_sample_rate: u32,
    pub max_bit_depth: u8,
    pub max_channels: u8,
    pub has_volume_control: bool,
    pub has_mute_control: bool,
}
```

### Uac2AudioFormatFfi

```rust
#[derive(Clone, Debug)]
pub struct Uac2AudioFormatFfi {
    pub sample_rate: u32,
    pub bit_depth: u8,
    pub channels: u8,
}
```

### Uac2StreamConfigFfi

```rust
#[derive(Clone, Debug)]
pub struct Uac2StreamConfigFfi {
    pub format: Uac2AudioFormatFfi,
    pub buffer_size: usize,
    pub num_buffers: usize,
}
```

### Uac2StateFfi

```rust
#[derive(Clone, Debug)]
pub enum Uac2StateFfi {
    Idle,
    Connecting,
    Connected,
    Streaming,
    Error,
}
```

### Uac2HotplugEventFfi

```rust
#[derive(Clone, Debug)]
pub struct Uac2HotplugEventFfi {
    pub device_id: String,
    pub connected: bool,
}
```

### Uac2ErrorFfi

```rust
#[derive(Clone, Debug)]
pub enum Uac2ErrorFfi {
    DeviceNotFound,
    DeviceBusy,
    PermissionDenied,
    ConnectionFailed,
    TransferFailed,
    UnsupportedFormat,
    Unknown { message: String },
}
```

## Type Conversion

### Rust to FFI

```rust
impl From<Uac2Device> for Uac2DeviceInfoFfi {
    fn from(device: Uac2Device) -> Self {
        Self {
            id: device.id,
            vendor_id: device.vendor_id,
            product_id: device.product_id,
            manufacturer: device.manufacturer,
            product: device.product,
            serial: device.serial,
            capabilities: device.capabilities.into(),
        }
    }
}
```

### FFI to Rust

```rust
impl From<Uac2StreamConfigFfi> for StreamConfig {
    fn from(config: Uac2StreamConfigFfi) -> Self {
        Self {
            format: config.format.into(),
            buffer_size: config.buffer_size,
            num_buffers: config.num_buffers,
        }
    }
}
```

## Error Handling

### Rust Error to FFI Error

```rust
impl From<Uac2Error> for Uac2ErrorFfi {
    fn from(error: Uac2Error) -> Self {
        match error {
            Uac2Error::DeviceNotFound => Self::DeviceNotFound,
            Uac2Error::DeviceBusy => Self::DeviceBusy,
            Uac2Error::PermissionDenied => Self::PermissionDenied,
            Uac2Error::ConnectionLost => Self::ConnectionFailed,
            Uac2Error::TransferFailed => Self::TransferFailed,
            Uac2Error::UnsupportedFormat => Self::UnsupportedFormat,
            _ => Self::Unknown {
                message: error.to_string(),
            },
        }
    }
}
```

### Dart Error Handling

```dart
try {
  await uac2ConnectDevice(deviceId);
} on FfiException catch (e) {
  // Handle FFI error
  final error = Uac2Exception.fromFfi(e);
  print('Error: ${error.message}');
}
```

## Stream Handling

### Rust Stream

```rust
pub fn uac2_state_stream() -> impl Stream<Item = Uac2StateFfi> {
    let (tx, rx) = mpsc::channel(100);
    
    // Spawn task to send state updates
    tokio::spawn(async move {
        // Send state updates to tx
    });
    
    ReceiverStream::new(rx)
}
```

### Dart Stream

```dart
Stream<Uac2State> get deviceStateStream {
  return uac2StateStream().map((state) {
    return Uac2State.fromFfi(state);
  });
}
```

## Code Generation

### Generate Bindings

```bash
# Generate Dart and Rust bindings
flutter_rust_bridge_codegen \
  --rust-input rust/src/api/audio_api.rs \
  --dart-output lib/bridge/audio_bridge.dart
```

### Build Process

1. Define Rust API with `#[flutter_rust_bridge::frb]` attributes
2. Run code generator
3. Generated Dart bindings in `lib/bridge/`
4. Generated Rust bindings in `rust/src/bridge/`
5. Build Rust library
6. Flutter imports generated Dart code

## Performance Considerations

### Synchronous vs Asynchronous

- **Sync**: Fast operations (< 1ms)
- **Async**: Slow operations, I/O, blocking calls

```rust
// Sync - fast operation
#[flutter_rust_bridge::frb(sync)]
pub fn uac2_get_volume() -> Result<f32, Uac2ErrorFfi> {
    // Fast operation
}

// Async - slow operation
pub async fn uac2_enumerate_devices() -> Result<Vec<Uac2DeviceInfoFfi>, Uac2ErrorFfi> {
    // Potentially slow operation
}
```

### Memory Management

- Rust owns data
- FFI types are cloned for transfer
- Dart receives owned data
- No manual memory management needed

### Zero-Copy

For large data transfers:
- Use external buffers
- Share memory via pointers
- Requires unsafe code

## Thread Safety

- FFI calls can be made from any Dart isolate
- Rust implementation must be thread-safe
- Use `Arc` and `Mutex` for shared state
- Streams use channels for thread communication

## Debugging

### Enable Logging

```rust
// In Rust
tracing::debug!("FFI call: uac2_connect_device({})", device_id);
```

```dart
// In Dart
print('Calling uac2_connect_device($deviceId)');
```

### Error Context

Add context to errors:

```rust
uac2_connect_device(device_id)
    .map_err(|e| e.with_context("FFI: connect_device"))?
```

## Testing

### Rust Tests

```rust
#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_ffi_type_conversion() {
        let device = create_test_device();
        let ffi: Uac2DeviceInfoFfi = device.into();
        assert_eq!(ffi.id, "test-device");
    }
}
```

### Dart Tests

```dart
test('FFI device enumeration', () async {
  final devices = await uac2EnumerateDevices();
  expect(devices, isNotEmpty);
});
```

## Related Documentation

- [Rust API](rust-api.md)
- [Flutter API](flutter-api.md)
- [flutter_rust_bridge Documentation](https://cjycode.com/flutter_rust_bridge/)
