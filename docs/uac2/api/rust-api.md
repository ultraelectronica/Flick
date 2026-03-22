# Rust API Reference

This document describes the public Rust API for the UAC 2.0 implementation.

## Core Types

### Uac2Device

Represents a USB Audio Class 2.0 device.

```rust
pub struct Uac2Device {
    pub id: String,
    pub vendor_id: u16,
    pub product_id: u16,
    pub manufacturer: String,
    pub product: String,
    pub serial: String,
    pub capabilities: DeviceCapabilities,
}
```

**Methods:**

```rust
impl Uac2Device {
    /// Connect to the device
    pub fn connect(&mut self) -> Result<(), Uac2Error>;
    
    /// Disconnect from the device
    pub fn disconnect(&mut self) -> Result<(), Uac2Error>;
    
    /// Check if device is connected
    pub fn is_connected(&self) -> bool;
    
    /// Get device capabilities
    pub fn capabilities(&self) -> &DeviceCapabilities;
    
    /// Start audio streaming
    pub fn start_stream(&mut self, config: StreamConfig) -> Result<(), Uac2Error>;
    
    /// Stop audio streaming
    pub fn stop_stream(&mut self) -> Result<(), Uac2Error>;
}
```

### DeviceCapabilities

Device audio capabilities.

```rust
pub struct DeviceCapabilities {
    pub supported_formats: Vec<AudioFormat>,
    pub max_sample_rate: u32,
    pub max_bit_depth: u8,
    pub max_channels: u8,
    pub has_volume_control: bool,
    pub has_mute_control: bool,
}
```

**Methods:**

```rust
impl DeviceCapabilities {
    /// Find best matching format
    pub fn find_best_format(&self, source: &AudioFormat) -> Option<AudioFormat>;
    
    /// Check if format is supported
    pub fn supports_format(&self, format: &AudioFormat) -> bool;
    
    /// Get all supported sample rates
    pub fn sample_rates(&self) -> Vec<u32>;
}
```

### AudioFormat

Audio format specification.

```rust
pub struct AudioFormat {
    pub sample_rate: u32,
    pub bit_depth: u8,
    pub channels: u8,
    pub format_type: FormatType,
}
```

**Methods:**

```rust
impl AudioFormat {
    /// Create new format
    pub fn new(sample_rate: u32, bit_depth: u8, channels: u8) -> Self;
    
    /// Check if formats match exactly
    pub fn matches(&self, other: &AudioFormat) -> bool;
    
    /// Check if conversion is needed
    pub fn needs_conversion(&self, other: &AudioFormat) -> bool;
    
    /// Calculate bytes per sample
    pub fn bytes_per_sample(&self) -> usize;
    
    /// Calculate bytes per frame
    pub fn bytes_per_frame(&self) -> usize;
}
```

### StreamConfig

Stream configuration.

```rust
pub struct StreamConfig {
    pub format: AudioFormat,
    pub buffer_size: usize,
    pub num_buffers: usize,
}
```

**Methods:**

```rust
impl StreamConfig {
    /// Create default configuration
    pub fn default_for_format(format: AudioFormat) -> Self;
    
    /// Calculate latency in milliseconds
    pub fn latency_ms(&self) -> f64;
    
    /// Validate configuration
    pub fn validate(&self) -> Result<(), Uac2Error>;
}
```

## Device Management

### enumerate_devices

Enumerate all UAC 2.0 devices.

```rust
pub fn enumerate_devices() -> Result<Vec<Uac2Device>, Uac2Error>
```

**Returns:** List of discovered devices

**Errors:**
- `UsbError`: USB subsystem error
- `PermissionDenied`: Insufficient permissions

**Example:**

```rust
let devices = enumerate_devices()?;
for device in devices {
    println!("Found: {} {}", device.manufacturer, device.product);
}
```

### get_device_by_id

Get device by ID.

```rust
pub fn get_device_by_id(id: &str) -> Result<Uac2Device, Uac2Error>
```

**Parameters:**
- `id`: Device identifier

**Returns:** Device if found

**Errors:**
- `DeviceNotFound`: Device not found

### monitor_hotplug

Monitor device connection/disconnection.

```rust
pub fn monitor_hotplug<F>(callback: F) -> Result<(), Uac2Error>
where
    F: Fn(HotplugEvent) + Send + 'static
```

**Parameters:**
- `callback`: Function called on device events

**Example:**

```rust
monitor_hotplug(|event| {
    match event {
        HotplugEvent::Connected(device) => println!("Connected: {}", device.id),
        HotplugEvent::Disconnected(id) => println!("Disconnected: {}", id),
    }
})?;
```

## Audio Sink

### Uac2AudioSink

Audio sink for UAC 2.0 devices.

```rust
pub struct Uac2AudioSink {
    device: Uac2Device,
    config: StreamConfig,
    pipeline: AudioPipeline,
}
```

**Methods:**

```rust
impl Uac2AudioSink {
    /// Create new audio sink
    pub fn new(device: Uac2Device, config: StreamConfig) -> Result<Self, Uac2Error>;
    
    /// Start streaming
    pub fn start(&mut self) -> Result<(), Uac2Error>;
    
    /// Stop streaming
    pub fn stop(&mut self) -> Result<(), Uac2Error>;
    
    /// Write audio data
    pub fn write(&mut self, data: &[f32]) -> Result<usize, Uac2Error>;
    
    /// Get buffer fill level (0.0 to 1.0)
    pub fn buffer_fill(&self) -> f32;
}
```

**Trait Implementation:**

```rust
impl AudioSink for Uac2AudioSink {
    fn write(&mut self, data: &[f32]) -> Result<(), AudioError>;
    fn flush(&mut self) -> Result<(), AudioError>;
}
```

## Format Negotiation

### FormatNegotiator

Negotiates audio format between source and device.

```rust
pub struct FormatNegotiator;
```

**Methods:**

```rust
impl FormatNegotiator {
    /// Find best matching format
    pub fn negotiate(
        source: &AudioFormat,
        capabilities: &DeviceCapabilities
    ) -> Result<AudioFormat, Uac2Error>;
    
    /// Check if exact match exists
    pub fn has_exact_match(
        source: &AudioFormat,
        capabilities: &DeviceCapabilities
    ) -> bool;
}
```

## Control Requests

### set_volume

Set device volume.

```rust
pub fn set_volume(device: &mut Uac2Device, volume: f32) -> Result<(), Uac2Error>
```

**Parameters:**
- `device`: Target device
- `volume`: Volume level (0.0 to 1.0)

### get_volume

Get device volume.

```rust
pub fn get_volume(device: &Uac2Device) -> Result<f32, Uac2Error>
```

**Returns:** Current volume (0.0 to 1.0)

### set_mute

Set mute state.

```rust
pub fn set_mute(device: &mut Uac2Device, muted: bool) -> Result<(), Uac2Error>
```

**Parameters:**
- `device`: Target device
- `muted`: Mute state

### get_mute

Get mute state.

```rust
pub fn get_mute(device: &Uac2Device) -> Result<bool, Uac2Error>
```

**Returns:** Current mute state

## Error Types

### Uac2Error

Main error type.

```rust
pub enum Uac2Error {
    UsbError(rusb::Error),
    DeviceNotFound,
    DeviceBusy,
    PermissionDenied,
    InvalidDescriptor,
    UnsupportedFormat,
    TransferFailed,
    ConnectionLost,
    // ... more variants
}
```

**Methods:**

```rust
impl Uac2Error {
    /// Add context to error
    pub fn with_context(self, context: &str) -> Self;
    
    /// Check if error is recoverable
    pub fn is_recoverable(&self) -> bool;
    
    /// Get user-friendly message
    pub fn user_message(&self) -> String;
}
```

## Logging

### configure_logging

Configure UAC 2.0 logging.

```rust
pub fn configure_logging(level: LogLevel) -> Result<(), Uac2Error>
```

**Parameters:**
- `level`: Log level (Error, Warn, Info, Debug, Trace)

**Example:**

```rust
configure_logging(LogLevel::Debug)?;
```

## Constants

```rust
/// USB Audio Class code
pub const USB_CLASS_AUDIO: u8 = 0x01;

/// UAC 2.0 subclass
pub const USB_SUBCLASS_AUDIOSTREAMING: u8 = 0x02;

/// UAC 2.0 protocol
pub const USB_PROTOCOL_UAC2: u8 = 0x20;

/// Default buffer size (samples)
pub const DEFAULT_BUFFER_SIZE: usize = 2048;

/// Default number of transfer buffers
pub const DEFAULT_NUM_BUFFERS: usize = 4;
```

## Feature Flags

The UAC 2.0 implementation is behind a feature flag:

```toml
[dependencies]
flick_player = { version = "0.1", features = ["uac2"] }
```

## Thread Safety

- `Uac2Device`: Not `Send` or `Sync` (contains USB handle)
- `DeviceCapabilities`: `Send + Sync`
- `AudioFormat`: `Send + Sync`
- `Uac2AudioSink`: `Send` (for use in audio thread)

## Related Documentation

- [Flutter API](flutter-api.md)
- [FFI Bridge](ffi-bridge.md)
- [Examples](../examples/basic-usage.md)
