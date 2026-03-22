# Getting Started

This guide helps you integrate UAC 2.0 support into your application.

## Prerequisites

### Hardware
- Android device with USB Host (OTG) support
- USB Audio Class 2.0 compatible DAC or AMP
- USB OTG cable or adapter

### Software
- Flutter SDK 3.10+
- Rust toolchain (stable)
- Android SDK
- USB debugging enabled

## Quick Start

### 1. Enable UAC 2.0 Feature

Add the feature flag in `Cargo.toml`:

```toml
[dependencies]
flick_player = { version = "0.1", features = ["uac2"] }
```

### 2. Request USB Permissions

On Android, declare USB host feature in `AndroidManifest.xml`:

```xml
<uses-feature
    android:name="android.hardware.usb.host"
    android:required="false" />

<uses-permission android:name="android.permission.USB_PERMISSION" />
```

### 3. Initialize Service

In your Flutter app:

```dart
import 'package:flick_player/services/uac2_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize UAC2 service
  await Uac2Service.instance.initialize();
  
  runApp(MyApp());
}
```

### 4. Enumerate Devices

```dart
final devices = await Uac2Service.instance.enumerateDevices();

if (devices.isNotEmpty) {
  print('Found ${devices.length} UAC 2.0 devices');
  for (final device in devices) {
    print('${device.manufacturer} ${device.product}');
  }
}
```

### 5. Connect to Device

```dart
final device = devices.first;

try {
  await Uac2Service.instance.connectDevice(device.id);
  print('Connected to ${device.product}');
} on Uac2Exception catch (e) {
  print('Connection failed: ${e.message}');
}
```

### 6. Start Streaming

```dart
// Get device capabilities
final caps = await Uac2Service.instance.getDeviceCapabilities(device.id);

// Select best format
final format = caps.supportedFormats.first;

// Configure stream
final config = Uac2StreamConfig(
  format: format,
  bufferSize: 2048,
  numBuffers: 4,
);

// Start streaming
await Uac2Service.instance.startStream(config);
print('Streaming at ${format.sampleRate}Hz, ${format.bitDepth}-bit');
```

## Basic Example

Complete example:

```dart
import 'package:flutter/material.dart';
import 'package:flick_player/services/uac2_service.dart';

class Uac2Example extends StatefulWidget {
  @override
  _Uac2ExampleState createState() => _Uac2ExampleState();
}

class _Uac2ExampleState extends State<Uac2Example> {
  List<Uac2DeviceInfo> _devices = [];
  Uac2DeviceInfo? _selectedDevice;
  Uac2State _state = Uac2State.idle;
  
  @override
  void initState() {
    super.initState();
    _loadDevices();
    _listenToState();
  }
  
  Future<void> _loadDevices() async {
    try {
      final devices = await Uac2Service.instance.enumerateDevices();
      setState(() {
        _devices = devices;
      });
    } catch (e) {
      print('Error loading devices: $e');
    }
  }
  
  void _listenToState() {
    Uac2Service.instance.deviceStateStream.listen((state) {
      setState(() {
        _state = state;
      });
    });
  }
  
  Future<void> _connectDevice(Uac2DeviceInfo device) async {
    try {
      await Uac2Service.instance.connectDevice(device.id);
      
      final caps = await Uac2Service.instance.getDeviceCapabilities(device.id);
      final format = caps.supportedFormats.first;
      final config = Uac2StreamConfig(format: format);
      
      await Uac2Service.instance.startStream(config);
      
      setState(() {
        _selectedDevice = device;
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connection failed: $e')),
      );
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('UAC 2.0 Devices'),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh),
            onPressed: _loadDevices,
          ),
        ],
      ),
      body: Column(
        children: [
          // Status indicator
          Container(
            padding: EdgeInsets.all(16),
            color: _stateColor(_state),
            child: Row(
              children: [
                Icon(_stateIcon(_state), color: Colors.white),
                SizedBox(width: 8),
                Text(
                  _stateText(_state),
                  style: TextStyle(color: Colors.white),
                ),
              ],
            ),
          ),
          
          // Device list
          Expanded(
            child: ListView.builder(
              itemCount: _devices.length,
              itemBuilder: (context, index) {
                final device = _devices[index];
                final isSelected = device.id == _selectedDevice?.id;
                
                return ListTile(
                  leading: Icon(Icons.headset),
                  title: Text('${device.manufacturer} ${device.product}'),
                  subtitle: Text('${device.capabilities.maxSampleRate}Hz, ${device.capabilities.maxBitDepth}-bit'),
                  trailing: isSelected ? Icon(Icons.check, color: Colors.green) : null,
                  onTap: () => _connectDevice(device),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
  
  Color _stateColor(Uac2State state) {
    switch (state) {
      case Uac2State.idle:
        return Colors.grey;
      case Uac2State.connecting:
        return Colors.orange;
      case Uac2State.connected:
      case Uac2State.streaming:
        return Colors.green;
      case Uac2State.error:
        return Colors.red;
    }
  }
  
  IconData _stateIcon(Uac2State state) {
    switch (state) {
      case Uac2State.idle:
        return Icons.power_off;
      case Uac2State.connecting:
        return Icons.sync;
      case Uac2State.connected:
      case Uac2State.streaming:
        return Icons.check_circle;
      case Uac2State.error:
        return Icons.error;
    }
  }
  
  String _stateText(Uac2State state) {
    switch (state) {
      case Uac2State.idle:
        return 'No device connected';
      case Uac2State.connecting:
        return 'Connecting...';
      case Uac2State.connected:
        return 'Connected';
      case Uac2State.streaming:
        return 'Streaming';
      case Uac2State.error:
        return 'Error';
    }
  }
}
```

## Hot-Plug Support

Listen for device connection/disconnection:

```dart
Uac2Service.instance.hotplugStream.listen((event) {
  if (event.connected) {
    print('Device connected: ${event.deviceId}');
    // Optionally auto-connect
  } else {
    print('Device disconnected: ${event.deviceId}');
    // Handle disconnection
  }
});
```

## Error Handling

Always handle errors:

```dart
try {
  await Uac2Service.instance.connectDevice(deviceId);
} on Uac2Exception catch (e) {
  switch (e.code) {
    case Uac2ErrorCode.permissionDenied:
      // Show permission dialog
      break;
    case Uac2ErrorCode.deviceBusy:
      // Device in use by another app
      break;
    case Uac2ErrorCode.deviceNotFound:
      // Device disconnected
      break;
    default:
      // Generic error
      break;
  }
}
```

## Next Steps

- [Device Compatibility](device-compatibility.md) - Check supported devices
- [Advanced Usage](../examples/advanced-usage.md) - Complex scenarios
- [Troubleshooting](troubleshooting.md) - Common issues

## Common Issues

### No Devices Found

- Check USB OTG cable connection
- Verify device supports USB Host
- Check USB permissions in Android settings

### Permission Denied

- Grant USB permission when prompted
- Check AndroidManifest.xml configuration

### Connection Failed

- Ensure device is not in use by another app
- Try disconnecting and reconnecting device
- Check device compatibility

## Related Documentation

- [API Reference](../api/flutter-api.md)
- [Architecture](../architecture/overview.md)
- [Examples](../examples/basic-usage.md)
