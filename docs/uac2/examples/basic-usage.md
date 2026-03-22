# Basic Usage Examples

Simple examples for common UAC 2.0 tasks.

## Example 1: List Devices

Enumerate and display all connected UAC 2.0 devices.

```dart
import 'package:flick_player/services/uac2_service.dart';

Future<void> listDevices() async {
  try {
    final devices = await Uac2Service.instance.enumerateDevices();
    
    if (devices.isEmpty) {
      print('No UAC 2.0 devices found');
      return;
    }
    
    print('Found ${devices.length} device(s):');
    for (final device in devices) {
      print('');
      print('Device: ${device.manufacturer} ${device.product}');
      print('  ID: ${device.id}');
      print('  VID: 0x${device.vendorId.toRadixString(16)}');
      print('  PID: 0x${device.productId.toRadixString(16)}');
      print('  Serial: ${device.serial}');
      
      final caps = device.capabilities;
      print('  Max sample rate: ${caps.maxSampleRate} Hz');
      print('  Max bit depth: ${caps.maxBitDepth}-bit');
      print('  Max channels: ${caps.maxChannels}');
      print('  Volume control: ${caps.hasVolumeControl}');
      print('  Mute control: ${caps.hasMuteControl}');
    }
  } on Uac2Exception catch (e) {
    print('Error: ${e.message}');
  }
}
```

## Example 2: Connect to Device

Connect to a specific device and start streaming.

```dart
Future<void> connectToDevice(String deviceId) async {
  try {
    // Connect to device
    print('Connecting to device...');
    await Uac2Service.instance.connectDevice(deviceId);
    print('Connected!');
    
    // Get capabilities
    final caps = await Uac2Service.instance.getDeviceCapabilities(deviceId);
    
    // Select best format
    final format = caps.supportedFormats.first;
    print('Using format: ${format.sampleRate}Hz, ${format.bitDepth}-bit, ${format.channels}ch');
    
    // Configure stream
    final config = Uac2StreamConfig(format: format);
    
    // Start streaming
    print('Starting stream...');
    await Uac2Service.instance.startStream(config);
    print('Streaming!');
    
  } on Uac2Exception catch (e) {
    print('Error: ${e.message}');
  }
}
```

## Example 3: Monitor Device State

Listen to device state changes.

```dart
void monitorDeviceState() {
  Uac2Service.instance.deviceStateStream.listen((state) {
    switch (state) {
      case Uac2State.idle:
        print('State: Idle');
        break;
      case Uac2State.connecting:
        print('State: Connecting...');
        break;
      case Uac2State.connected:
        print('State: Connected');
        break;
      case Uac2State.streaming:
        print('State: Streaming');
        break;
      case Uac2State.error:
        print('State: Error');
        break;
    }
  });
}
```

## Example 4: Handle Hot-Plug Events

Respond to device connection/disconnection.

```dart
void handleHotplug() {
  Uac2Service.instance.hotplugStream.listen((event) {
    if (event.connected) {
      print('Device connected: ${event.deviceId}');
      
      // Optionally auto-connect
      connectToDevice(event.deviceId);
    } else {
      print('Device disconnected: ${event.deviceId}');
      
      // Handle disconnection
      // (fallback to default audio is automatic)
    }
  });
}
```

## Example 5: Volume Control

Control device volume.

```dart
Future<void> controlVolume() async {
  try {
    // Get current volume
    final volume = await Uac2Service.instance.getVolume();
    print('Current volume: ${(volume * 100).toInt()}%');
    
    // Set volume to 50%
    await Uac2Service.instance.setVolume(0.5);
    print('Volume set to 50%');
    
    // Mute
    await Uac2Service.instance.setMute(true);
    print('Muted');
    
    // Unmute
    await Uac2Service.instance.setMute(false);
    print('Unmuted');
    
  } on Uac2Exception catch (e) {
    print('Error: ${e.message}');
  }
}
```

## Example 6: Format Selection

Select optimal audio format.

```dart
Future<Uac2AudioFormat> selectBestFormat(
  Uac2Capabilities caps,
  Uac2AudioFormat? preferredFormat,
) async {
  // If preferred format is supported, use it
  if (preferredFormat != null && 
      caps.supportedFormats.contains(preferredFormat)) {
    return preferredFormat;
  }
  
  // Otherwise, select highest quality
  return caps.supportedFormats.reduce((a, b) {
    final qualityA = a.sampleRate * a.bitDepth;
    final qualityB = b.sampleRate * b.bitDepth;
    return qualityA > qualityB ? a : b;
  });
}
```

## Example 7: Error Handling

Handle common errors gracefully.

```dart
Future<void> connectWithErrorHandling(String deviceId) async {
  try {
    await Uac2Service.instance.connectDevice(deviceId);
  } on Uac2Exception catch (e) {
    switch (e.code) {
      case Uac2ErrorCode.deviceNotFound:
        print('Device not found. Please check connection.');
        break;
        
      case Uac2ErrorCode.deviceBusy:
        print('Device is busy. Close other audio apps.');
        break;
        
      case Uac2ErrorCode.permissionDenied:
        print('Permission denied. Please grant USB access.');
        // Request permission
        await Uac2Service.instance.requestPermission(deviceId);
        // Retry
        await Uac2Service.instance.connectDevice(deviceId);
        break;
        
      case Uac2ErrorCode.unsupportedFormat:
        print('Format not supported. Trying different format...');
        // Try with different format
        break;
        
      default:
        print('Connection failed: ${e.message}');
        break;
    }
  }
}
```

## Example 8: Simple Player Integration

Integrate with audio player.

```dart
class SimpleUac2Player {
  bool _isConnected = false;
  String? _currentDeviceId;
  
  Future<void> initialize() async {
    // Monitor state
    Uac2Service.instance.deviceStateStream.listen((state) {
      _isConnected = state == Uac2State.connected || 
                     state == Uac2State.streaming;
    });
    
    // Monitor hot-plug
    Uac2Service.instance.hotplugStream.listen((event) {
      if (!event.connected && event.deviceId == _currentDeviceId) {
        print('Device disconnected, falling back to default audio');
        _currentDeviceId = null;
      }
    });
  }
  
  Future<void> selectDevice(String deviceId) async {
    try {
      await Uac2Service.instance.connectDevice(deviceId);
      
      final caps = await Uac2Service.instance.getDeviceCapabilities(deviceId);
      final format = caps.supportedFormats.first;
      final config = Uac2StreamConfig(format: format);
      
      await Uac2Service.instance.startStream(config);
      
      _currentDeviceId = deviceId;
      print('Now playing through UAC 2.0 device');
    } catch (e) {
      print('Failed to select device: $e');
    }
  }
  
  Future<void> disconnect() async {
    if (_currentDeviceId != null) {
      await Uac2Service.instance.stopStream();
      await Uac2Service.instance.disconnectDevice();
      _currentDeviceId = null;
      print('Disconnected, using default audio');
    }
  }
  
  bool get isUsingUac2 => _isConnected;
}
```

## Example 9: Device Preferences

Save and restore device preferences.

```dart
import 'package:flick_player/services/uac2_preferences_service.dart';

class DevicePreferences {
  final _prefs = Uac2PreferencesService.instance;
  
  Future<void> savePreferredDevice(String deviceId) async {
    await _prefs.setSelectedDeviceId(deviceId);
    await _prefs.setAutoConnect(true);
  }
  
  Future<void> restorePreferredDevice() async {
    final deviceId = await _prefs.getSelectedDeviceId();
    final autoConnect = await _prefs.getAutoConnect();
    
    if (deviceId != null && autoConnect) {
      try {
        await Uac2Service.instance.connectDevice(deviceId);
        print('Auto-connected to preferred device');
      } catch (e) {
        print('Failed to auto-connect: $e');
      }
    }
  }
  
  Future<void> clearPreferences() async {
    await _prefs.setSelectedDeviceId(null);
    await _prefs.setAutoConnect(false);
  }
}
```

## Example 10: Format Comparison

Compare source and device formats.

```dart
void compareFormats(
  Uac2AudioFormat sourceFormat,
  Uac2Capabilities deviceCaps,
) {
  print('Source format: ${sourceFormat.sampleRate}Hz, '
        '${sourceFormat.bitDepth}-bit, ${sourceFormat.channels}ch');
  
  // Check for exact match
  final exactMatch = deviceCaps.supportedFormats
      .any((f) => f.sampleRate == sourceFormat.sampleRate &&
                  f.bitDepth == sourceFormat.bitDepth &&
                  f.channels == sourceFormat.channels);
  
  if (exactMatch) {
    print('✓ Bit-perfect playback possible (exact match)');
  } else {
    print('⚠ Conversion required:');
    
    // Find closest match
    final closest = deviceCaps.supportedFormats.reduce((a, b) {
      final diffA = (a.sampleRate - sourceFormat.sampleRate).abs() +
                    (a.bitDepth - sourceFormat.bitDepth).abs();
      final diffB = (b.sampleRate - sourceFormat.sampleRate).abs() +
                    (b.bitDepth - sourceFormat.bitDepth).abs();
      return diffA < diffB ? a : b;
    });
    
    print('  Closest match: ${closest.sampleRate}Hz, '
          '${closest.bitDepth}-bit, ${closest.channels}ch');
    
    if (closest.sampleRate != sourceFormat.sampleRate) {
      print('  - Sample rate conversion: '
            '${sourceFormat.sampleRate} → ${closest.sampleRate} Hz');
    }
    
    if (closest.bitDepth != sourceFormat.bitDepth) {
      print('  - Bit depth conversion: '
            '${sourceFormat.bitDepth} → ${closest.bitDepth} bit');
    }
    
    if (closest.channels != sourceFormat.channels) {
      print('  - Channel conversion: '
            '${sourceFormat.channels} → ${closest.channels} channels');
    }
  }
}
```

## Running the Examples

### From Dart

```dart
void main() async {
  // Initialize
  await Uac2Service.instance.initialize();
  
  // Run examples
  await listDevices();
  
  final devices = await Uac2Service.instance.enumerateDevices();
  if (devices.isNotEmpty) {
    await connectToDevice(devices.first.id);
  }
}
```

### From Flutter App

```dart
class ExamplesScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('UAC 2.0 Examples')),
      body: ListView(
        children: [
          ListTile(
            title: Text('List Devices'),
            onTap: () => listDevices(),
          ),
          ListTile(
            title: Text('Monitor State'),
            onTap: () => monitorDeviceState(),
          ),
          ListTile(
            title: Text('Handle Hot-Plug'),
            onTap: () => handleHotplug(),
          ),
        ],
      ),
    );
  }
}
```

## Related Documentation

- [Advanced Usage](advanced-usage.md)
- [API Reference](../api/flutter-api.md)
- [Getting Started](../guides/getting-started.md)
