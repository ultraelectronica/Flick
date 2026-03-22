# Troubleshooting

Common issues and solutions for UAC 2.0 implementation.

## Device Detection Issues

### No Devices Found

**Symptoms:** `enumerateDevices()` returns empty list

**Causes:**
- Device not connected
- USB Host not supported
- USB permissions not granted
- Device not UAC 2.0 compatible

**Solutions:**

1. Check physical connection:
   ```
   - Verify USB cable is connected
   - Try different USB cable
   - Check OTG adapter if used
   ```

2. Verify USB Host support:
   ```dart
   // Check if device supports USB Host
   final hasUsbHost = await platform.hasUsbHost();
   if (!hasUsbHost) {
     print('Device does not support USB Host');
   }
   ```

3. Check USB permissions:
   ```dart
   // Request permission
   await Uac2Service.instance.requestPermission(deviceId);
   ```

4. Verify device compatibility:
   ```
   - Check if device is UAC 2.0 (not UAC 1.0)
   - Some devices may need firmware update
   - Check manufacturer specifications
   ```

### Device Detected But Can't Connect

**Symptoms:** Device appears in list but connection fails

**Causes:**
- Device busy (used by another app)
- Insufficient permissions
- Device in wrong mode
- Power issues

**Solutions:**

1. Close other audio apps:
   ```
   - Close music players
   - Close audio recording apps
   - Restart device if needed
   ```

2. Check permissions:
   ```
   - Grant USB permission when prompted
   - Check app permissions in Settings
   ```

3. Check device mode:
   ```
   - Some devices have multiple modes
   - Switch to UAC 2.0 mode if available
   - Check device manual
   ```

4. Power issues:
   ```
   - Use powered USB hub for high-power devices
   - Try external power for device
   - Check USB cable quality
   ```

## Connection Issues

### Connection Drops Randomly

**Symptoms:** Device disconnects during playback

**Causes:**
- Loose USB connection
- Power issues
- USB cable quality
- Device overheating

**Solutions:**

1. Check physical connection:
   ```
   - Secure USB connections
   - Try different USB cable
   - Avoid moving device during playback
   ```

2. Power management:
   ```
   - Disable battery optimization for app
   - Use external power for device
   - Avoid low battery situations
   ```

3. Reduce load:
   ```
   - Close background apps
   - Lower sample rate if possible
   - Increase buffer size
   ```

### Permission Denied Error

**Symptoms:** `PermissionDenied` error when connecting

**Solutions:**

1. Request permission explicitly:
   ```dart
   try {
     await Uac2Service.instance.requestPermission(deviceId);
     await Uac2Service.instance.connectDevice(deviceId);
   } catch (e) {
     print('Permission error: $e');
   }
   ```

2. Check AndroidManifest.xml:
   ```xml
   <uses-permission android:name="android.permission.USB_PERMISSION" />
   ```

3. Grant permission in Settings:
   ```
   Settings > Apps > Your App > Permissions > USB
   ```

## Audio Quality Issues

### Audio Glitches or Stuttering

**Symptoms:** Clicks, pops, or dropouts during playback

**Causes:**
- Buffer underrun
- CPU overload
- USB bandwidth issues
- Interference

**Solutions:**

1. Increase buffer size:
   ```dart
   final config = Uac2StreamConfig(
     format: format,
     bufferSize: 4096,  // Increase from 2048
     numBuffers: 8,     // Increase from 4
   );
   ```

2. Reduce CPU load:
   ```
   - Close background apps
   - Disable animations
   - Lower screen brightness
   - Enable performance mode
   ```

3. Check USB connection:
   ```
   - Use high-quality USB cable
   - Avoid USB hubs if possible
   - Keep cable short (< 1m)
   ```

4. Reduce sample rate:
   ```dart
   // Try lower sample rate
   final format = Uac2AudioFormat(
     sampleRate: 48000,  // Instead of 192000
     bitDepth: 24,
     channels: 2,
   );
   ```

### No Sound Output

**Symptoms:** Connected but no audio

**Causes:**
- Volume set to zero
- Device muted
- Wrong output selected
- Format mismatch

**Solutions:**

1. Check volume:
   ```dart
   final volume = await Uac2Service.instance.getVolume();
   if (volume == 0.0) {
     await Uac2Service.instance.setVolume(0.5);
   }
   ```

2. Check mute:
   ```dart
   final muted = await Uac2Service.instance.getMute();
   if (muted) {
     await Uac2Service.instance.setMute(false);
   }
   ```

3. Verify format:
   ```dart
   final caps = await Uac2Service.instance.getDeviceCapabilities(deviceId);
   if (!caps.supportsFormat(currentFormat)) {
     // Switch to supported format
   }
   ```

### Poor Audio Quality

**Symptoms:** Distorted or low-quality sound

**Causes:**
- Format conversion
- Low bit depth
- Low sample rate
- Device limitations

**Solutions:**

1. Use bit-perfect format:
   ```dart
   // Match source format exactly
   final sourceFormat = audioFile.format;
   final deviceFormat = caps.findBestFormat(sourceFormat);
   
   if (sourceFormat.matches(deviceFormat)) {
     print('Bit-perfect playback');
   }
   ```

2. Use highest quality:
   ```dart
   final bestFormat = caps.supportedFormats
       .reduce((a, b) => 
           a.sampleRate * a.bitDepth > b.sampleRate * b.bitDepth ? a : b);
   ```

## Performance Issues

### High CPU Usage

**Symptoms:** Device gets hot, battery drains fast

**Causes:**
- Format conversion
- High sample rate
- Large buffer processing

**Solutions:**

1. Avoid format conversion:
   ```dart
   // Use native format when possible
   if (caps.supportsFormat(sourceFormat)) {
     // No conversion needed
   }
   ```

2. Optimize buffer size:
   ```dart
   // Balance latency and CPU usage
   final config = Uac2StreamConfig(
     format: format,
     bufferSize: 2048,  // Not too large
     numBuffers: 4,     // Not too many
   );
   ```

### High Latency

**Symptoms:** Delay between action and sound

**Causes:**
- Large buffers
- Format conversion
- System audio routing

**Solutions:**

1. Reduce buffer size:
   ```dart
   final config = Uac2StreamConfig(
     format: format,
     bufferSize: 512,   // Smaller buffer
     numBuffers: 2,     // Fewer buffers
   );
   ```

2. Use native format:
   ```
   - Avoid sample rate conversion
   - Avoid bit depth conversion
   - Match source format exactly
   ```

## Error Messages

### "Transfer Failed"

**Cause:** USB transfer error

**Solutions:**
- Check USB connection
- Reduce buffer size
- Try different USB cable
- Restart device

### "Unsupported Format"

**Cause:** Device doesn't support requested format

**Solutions:**
- Check device capabilities
- Use supported format
- Try lower sample rate/bit depth

### "Device Busy"

**Cause:** Device in use by another app

**Solutions:**
- Close other audio apps
- Restart device
- Force stop conflicting apps

### "Connection Lost"

**Cause:** Device disconnected

**Solutions:**
- Check USB connection
- Reconnect device
- Check device power
- Try different USB port

## Logging and Debugging

### Enable Debug Logging

```rust
// In Rust
configure_logging(LogLevel::Debug)?;
```

```dart
// In Dart
Uac2Service.instance.setLogLevel(LogLevel.debug);
```

### View Logs

```bash
# Android logcat
adb logcat | grep -i uac2

# Filter by tag
adb logcat -s FlickPlayer:D UAC2:D
```

### Collect Diagnostic Info

```dart
final diagnostics = await Uac2Service.instance.getDiagnostics();
print('State: ${diagnostics.state}');
print('Device: ${diagnostics.deviceId}');
print('Format: ${diagnostics.currentFormat}');
print('Buffer fill: ${diagnostics.bufferFill}');
print('Underruns: ${diagnostics.underrunCount}');
print('Overruns: ${diagnostics.overrunCount}');
```

## Getting Help

### Before Asking for Help

Collect this information:

1. Device information:
   ```dart
   final device = await Uac2Service.instance.getCurrentDevice();
   print('Device: ${device.manufacturer} ${device.product}');
   print('VID: ${device.vendorId}');
   print('PID: ${device.productId}');
   ```

2. Capabilities:
   ```dart
   final caps = device.capabilities;
   print('Formats: ${caps.supportedFormats}');
   ```

3. Error details:
   ```
   - Full error message
   - Stack trace
   - Steps to reproduce
   ```

4. Environment:
   ```
   - Android version
   - Device model
   - App version
   - USB cable type
   ```

### Reporting Bugs

Include:
- Clear description
- Steps to reproduce
- Expected behavior
- Actual behavior
- Device information
- Logs (if available)

## Related Documentation

- [Getting Started](getting-started.md)
- [Device Compatibility](device-compatibility.md)
- [API Reference](../api/flutter-api.md)
