# Testing Guide

Comprehensive testing strategies for UAC 2.0 implementation.

## Testing Levels

### Unit Tests

Test individual components in isolation.

**Location:** `rust/src/uac2/tests/`

**Coverage:**
- Descriptor parsing
- Format negotiation
- Control requests
- Error handling
- Buffer management

**Example:**

```rust
#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_format_negotiation() {
        let source = AudioFormat::new(44100, 16, 2);
        let device_formats = vec![
            AudioFormat::new(48000, 24, 2),
            AudioFormat::new(44100, 16, 2),
        ];
        
        let negotiator = FormatNegotiator::new();
        let result = negotiator.negotiate(&source, &device_formats);
        
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), source);
    }
}
```

### Integration Tests

Test component interactions.

**Location:** `rust/tests/`

**Coverage:**
- Device enumeration
- Connection lifecycle
- Audio streaming
- Error recovery
- Hot-plug handling

**Example:**

```rust
#[test]
fn test_device_connection_lifecycle() {
    let devices = enumerate_devices().unwrap();
    assert!(!devices.is_empty());
    
    let mut device = devices[0].clone();
    
    // Connect
    device.connect().unwrap();
    assert!(device.is_connected());
    
    // Disconnect
    device.disconnect().unwrap();
    assert!(!device.is_connected());
}
```

### Performance Tests

Test performance characteristics.

**Location:** `rust/tests/uac2_performance_tests.rs`

**Metrics:**
- Latency
- CPU usage
- Memory usage
- Transfer success rate

**Example:**

```rust
#[test]
fn test_streaming_latency() {
    let mut sink = create_test_sink();
    
    let start = Instant::now();
    sink.write(&test_audio_data()).unwrap();
    let latency = start.elapsed();
    
    assert!(latency < Duration::from_millis(10));
}
```

## Test Scenarios

### Device Discovery

Test device enumeration:

```rust
#[test]
fn test_enumerate_devices() {
    let devices = enumerate_devices().unwrap();
    
    for device in devices {
        assert!(!device.id.is_empty());
        assert!(device.vendor_id > 0);
        assert!(device.product_id > 0);
        assert!(!device.manufacturer.is_empty());
    }
}
```

### Format Support

Test format capabilities:

```rust
#[test]
fn test_device_capabilities() {
    let device = get_test_device();
    let caps = device.capabilities();
    
    assert!(!caps.supported_formats.is_empty());
    assert!(caps.max_sample_rate >= 44100);
    assert!(caps.max_bit_depth >= 16);
    assert!(caps.max_channels >= 2);
}
```

### Audio Streaming

Test streaming functionality:

```rust
#[test]
fn test_audio_streaming() {
    let mut device = get_test_device();
    device.connect().unwrap();
    
    let config = StreamConfig::default_for_format(
        AudioFormat::new(48000, 24, 2)
    );
    
    device.start_stream(config).unwrap();
    
    // Stream audio
    let audio_data = generate_test_audio();
    device.write_audio(&audio_data).unwrap();
    
    device.stop_stream().unwrap();
    device.disconnect().unwrap();
}
```

### Error Handling

Test error scenarios:

```rust
#[test]
fn test_connection_error_handling() {
    let mut device = get_test_device();
    
    // Try to connect twice
    device.connect().unwrap();
    let result = device.connect();
    assert!(result.is_err());
    
    device.disconnect().unwrap();
}

#[test]
fn test_unsupported_format() {
    let mut device = get_test_device();
    device.connect().unwrap();
    
    // Try unsupported format
    let config = StreamConfig::default_for_format(
        AudioFormat::new(999999, 128, 99)
    );
    
    let result = device.start_stream(config);
    assert!(matches!(result, Err(Uac2Error::UnsupportedFormat)));
}
```

### Hot-Plug

Test device connection/disconnection:

```rust
#[test]
fn test_hotplug_events() {
    let (tx, rx) = mpsc::channel();
    
    monitor_hotplug(move |event| {
        tx.send(event).unwrap();
    }).unwrap();
    
    // Simulate device connection
    // (requires physical device or mock)
    
    let event = rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert!(matches!(event, HotplugEvent::Connected(_)));
}
```

## Bit-Perfect Verification

### Test Setup

1. Generate test audio file
2. Play through UAC 2.0 device
3. Record output
4. Compare input and output

### Test Audio Generation

```rust
fn generate_test_tone(frequency: f32, duration: f32, sample_rate: u32) -> Vec<f32> {
    let num_samples = (duration * sample_rate as f32) as usize;
    let mut samples = Vec::with_capacity(num_samples);
    
    for i in 0..num_samples {
        let t = i as f32 / sample_rate as f32;
        let sample = (2.0 * PI * frequency * t).sin();
        samples.push(sample);
    }
    
    samples
}
```

### Verification

```rust
#[test]
fn test_bit_perfect_playback() {
    let input = generate_test_tone(1000.0, 1.0, 48000);
    
    // Play through UAC 2.0
    let mut device = get_test_device();
    device.connect().unwrap();
    
    let config = StreamConfig::default_for_format(
        AudioFormat::new(48000, 24, 2)
    );
    device.start_stream(config).unwrap();
    device.write_audio(&input).unwrap();
    
    // Record output (requires loopback or external recording)
    let output = record_device_output(&device, input.len());
    
    // Compare
    let correlation = calculate_correlation(&input, &output);
    assert!(correlation > 0.999); // 99.9% correlation
    
    device.stop_stream().unwrap();
    device.disconnect().unwrap();
}
```

## Flutter Tests

### Widget Tests

Test UI components:

```dart
testWidgets('Device selector displays devices', (tester) async {
  final devices = [
    Uac2DeviceInfo(
      id: 'test-1',
      manufacturer: 'Test',
      product: 'DAC',
      capabilities: testCapabilities,
    ),
  ];
  
  await tester.pumpWidget(
    MaterialApp(
      home: Uac2DeviceSelector(
        devices: devices,
        onDeviceSelected: (_) {},
      ),
    ),
  );
  
  expect(find.text('Test DAC'), findsOneWidget);
});
```

### Integration Tests

Test service integration:

```dart
test('UAC2 service enumeration', () async {
  final devices = await Uac2Service.instance.enumerateDevices();
  expect(devices, isNotEmpty);
  
  for (final device in devices) {
    expect(device.id, isNotEmpty);
    expect(device.manufacturer, isNotEmpty);
  }
});
```

## Mock Testing

### Mock Device

For testing without physical device:

```rust
pub struct MockUac2Device {
    id: String,
    capabilities: DeviceCapabilities,
    connected: bool,
}

impl MockUac2Device {
    pub fn new() -> Self {
        Self {
            id: "mock-device".to_string(),
            capabilities: DeviceCapabilities::default(),
            connected: false,
        }
    }
}
```

### Mock Usage

```rust
#[test]
fn test_with_mock_device() {
    let mut device = MockUac2Device::new();
    
    device.connect().unwrap();
    assert!(device.is_connected());
    
    // Test functionality
}
```

## Continuous Integration

### GitHub Actions

```yaml
name: UAC2 Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    
    steps:
      - uses: actions/checkout@v2
      
      - name: Install Rust
        uses: actions-rs/toolchain@v1
        with:
          toolchain: stable
      
      - name: Run tests
        run: |
          cd rust
          cargo test --features uac2
      
      - name: Run integration tests
        run: |
          cd rust
          cargo test --test uac2_integration_tests
```

## Test Coverage

### Measure Coverage

```bash
# Install tarpaulin
cargo install cargo-tarpaulin

# Run with coverage
cargo tarpaulin --features uac2 --out Html
```

### Coverage Goals

- Unit tests: > 80%
- Integration tests: > 60%
- Critical paths: 100%

## Performance Benchmarks

### Criterion Benchmarks

```rust
use criterion::{black_box, criterion_group, criterion_main, Criterion};

fn benchmark_format_negotiation(c: &mut Criterion) {
    let source = AudioFormat::new(44100, 16, 2);
    let device_formats = create_test_formats();
    let negotiator = FormatNegotiator::new();
    
    c.bench_function("format_negotiation", |b| {
        b.iter(|| {
            negotiator.negotiate(
                black_box(&source),
                black_box(&device_formats)
            )
        })
    });
}

criterion_group!(benches, benchmark_format_negotiation);
criterion_main!(benches);
```

## Test Data

### Test Audio Files

Generate test files:

```bash
# Generate test tones
ffmpeg -f lavfi -i "sine=frequency=1000:duration=5" -ar 48000 -ac 2 test_1khz.wav
ffmpeg -f lavfi -i "sine=frequency=440:duration=5" -ar 96000 -ac 2 test_440hz.wav
```

### Test Descriptors

Create mock descriptors for testing:

```rust
fn create_test_descriptor() -> Vec<u8> {
    vec![
        // Configuration descriptor
        0x09, 0x02, 0x64, 0x00, 0x03, 0x01, 0x00, 0x80, 0xFA,
        // Interface descriptor
        0x09, 0x04, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00,
        // ... more descriptor data
    ]
}
```

## Related Documentation

- [Getting Started](getting-started.md)
- [API Reference](../api/rust-api.md)
- [Troubleshooting](troubleshooting.md)
