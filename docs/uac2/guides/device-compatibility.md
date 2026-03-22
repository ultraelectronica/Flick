# Device Compatibility

This guide covers UAC 2.0 device compatibility and testing.

## Requirements

### Minimum Requirements

Devices must meet these criteria:
- USB Audio Class 2.0 compliant
- Isochronous endpoint support
- PCM format support (minimum)
- Standard USB descriptors

### Recommended Features

For best experience:
- Multiple sample rate support (44.1, 48, 96, 192 kHz)
- Multiple bit depth support (16, 24, 32-bit)
- Volume and mute controls
- Low latency operation

## Tested Devices

### Fully Compatible

These devices have been tested and work perfectly:

| Manufacturer | Model | Max Sample Rate | Max Bit Depth | Notes |
|--------------|-------|-----------------|---------------|-------|
| FiiO | K5 Pro | 384 kHz | 32-bit | Excellent compatibility |
| Topping | D10s | 384 kHz | 32-bit | All features work |
| Schiit | Modi 3+ | 192 kHz | 24-bit | Stable operation |
| iFi | Zen DAC | 384 kHz | 32-bit | DSD support |

### Partially Compatible

These devices work with limitations:

| Manufacturer | Model | Limitation | Workaround |
|--------------|-------|------------|------------|
| Generic | USB DAC | No volume control | Use software volume |
| Older | UAC 1.0 devices | Not supported | Upgrade to UAC 2.0 |

### Known Issues

| Device | Issue | Status |
|--------|-------|--------|
| Some Realtek | Descriptor parsing fails | Under investigation |
| Budget DACs | Intermittent disconnects | Use shorter cable |

## Device Classification

### DAC Only

Pure digital-to-analog converters:
- No amplification
- Line-level output
- Requires external amplifier

### AMP Only

Pure amplifiers:
- Analog input
- Powered output
- Drives headphones/speakers

### DAC/AMP Combo

Combined units:
- Digital input
- Powered output
- Most common type

## Format Support

### Sample Rates

Common sample rates:
- **44.1 kHz**: CD quality
- **48 kHz**: Professional audio
- **88.2 kHz**: 2x CD quality
- **96 kHz**: High-resolution
- **176.4 kHz**: 4x CD quality
- **192 kHz**: Ultra high-resolution
- **352.8 kHz**: 8x CD quality
- **384 kHz**: Maximum supported

### Bit Depths

Supported bit depths:
- **16-bit**: CD quality, 96 dB dynamic range
- **24-bit**: High-resolution, 144 dB dynamic range
- **32-bit**: Professional/floating-point

### Channel Configurations

- **Mono**: 1 channel
- **Stereo**: 2 channels (most common)
- **Multi-channel**: 5.1, 7.1, etc.

## Testing Your Device

### Check Compatibility

```dart
final devices = await Uac2Service.instance.enumerateDevices();

for (final device in devices) {
  print('Device: ${device.manufacturer} ${device.product}');
  
  final caps = device.capabilities;
  print('Max sample rate: ${caps.maxSampleRate} Hz');
  print('Max bit depth: ${caps.maxBitDepth}-bit');
  print('Max channels: ${caps.maxChannels}');
  print('Volume control: ${caps.hasVolumeControl}');
  print('Mute control: ${caps.hasMuteControl}');
  
  print('Supported formats:');
  for (final format in caps.supportedFormats) {
    print('  ${format.sampleRate}Hz, ${format.bitDepth}-bit, ${format.channels}ch');
  }
}
```

### Test Streaming

```dart
// Try highest quality format
final bestFormat = caps.supportedFormats
    .reduce((a, b) => 
        a.sampleRate * a.bitDepth > b.sampleRate * b.bitDepth ? a : b);

final config = Uac2StreamConfig(format: bestFormat);

try {
  await Uac2Service.instance.startStream(config);
  print('Streaming successful at ${bestFormat.sampleRate}Hz, ${bestFormat.bitDepth}-bit');
} catch (e) {
  print('Streaming failed: $e');
}
```

### Verify Bit-Perfect

To verify bit-perfect playback:
1. Play a test tone (e.g., 1 kHz sine wave)
2. Record output with audio analyzer
3. Compare input and output waveforms
4. Verify no frequency response changes
5. Verify no added harmonics

## Platform Considerations

### Android

- Requires USB Host (OTG) support
- Some devices may need powered USB hub
- Check device power requirements
- Some ROMs may have USB audio issues

### Power Requirements

- Bus-powered devices: 500mA max (USB 2.0)
- High-power devices: May need external power
- Use powered USB hub if needed

## Troubleshooting

### Device Not Detected

1. Check USB connection
2. Verify USB Host support
3. Try different USB cable
4. Check device power

### Connection Fails

1. Check USB permissions
2. Close other audio apps
3. Restart device
4. Try different USB port

### Audio Glitches

1. Increase buffer size
2. Close background apps
3. Disable battery optimization
4. Use shorter USB cable

### No Sound

1. Check volume level
2. Verify device not muted
3. Check output connection
4. Try different format

## Reporting Issues

When reporting device issues, include:

- Device manufacturer and model
- USB VID and PID
- Supported formats (from capabilities)
- Error messages
- Android version
- Device model

Example:

```
Device: FiiO K5 Pro
VID: 0x1234
PID: 0x5678
Max format: 384kHz, 32-bit, 2ch
Error: Transfer timeout after 5 seconds
Android: 13
Phone: Samsung Galaxy S21
```

## Contributing

Help improve compatibility:

1. Test your device
2. Report results (working or not)
3. Provide device information
4. Submit fixes if possible

## Related Documentation

- [Getting Started](getting-started.md)
- [Troubleshooting](troubleshooting.md)
- [API Reference](../api/flutter-api.md)
