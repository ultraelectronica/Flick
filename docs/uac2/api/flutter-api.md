# Flutter API Reference

This document describes the Dart/Flutter API for UAC 2.0 integration.

## Uac2Service

Main service for UAC 2.0 device management.

**Location:** `lib/services/uac2_service.dart`

### Singleton Access

```dart
final uac2Service = Uac2Service.instance;
```

### Methods

#### enumerateDevices

Get list of connected UAC 2.0 devices.

```dart
Future<List<Uac2DeviceInfo>> enumerateDevices()
```

**Returns:** List of device information

**Throws:** `Uac2Exception` on error

**Example:**

```dart
try {
  final devices = await uac2Service.enumerateDevices();
  for (final device in devices) {
    print('${device.manufacturer} ${device.product}');
  }
} on Uac2Exception catch (e) {
  print('Error: ${e.message}');
}
```

#### connectDevice

Connect to a specific device.

```dart
Future<void> connectDevice(String deviceId)
```

**Parameters:**
- `deviceId`: Device identifier

**Throws:** `Uac2Exception` on connection failure

**Example:**

```dart
await uac2Service.connectDevice(device.id);
```

#### disconnectDevice

Disconnect from current device.

```dart
Future<void> disconnectDevice()
```

**Throws:** `Uac2Exception` on error

#### getDeviceCapabilities

Get capabilities of a device.

```dart
Future<Uac2Capabilities> getDeviceCapabilities(String deviceId)
```

**Parameters:**
- `deviceId`: Device identifier

**Returns:** Device capabilities

**Example:**

```dart
final caps = await uac2Service.getDeviceCapabilities(device.id);
print('Max sample rate: ${caps.maxSampleRate}');
```

#### startStream

Start audio streaming.

```dart
Future<void> startStream(Uac2StreamConfig config)
```

**Parameters:**
- `config`: Stream configuration

**Throws:** `Uac2Exception` on error

#### stopStream

Stop audio streaming.

```dart
Future<void> stopStream()
```

#### setVolume

Set device volume.

```dart
Future<void> setVolume(double volume)
```

**Parameters:**
- `volume`: Volume level (0.0 to 1.0)

#### getVolume

Get device volume.

```dart
Future<double> getVolume()
```

**Returns:** Current volume (0.0 to 1.0)

#### setMute

Set mute state.

```dart
Future<void> setMute(bool muted)
```

**Parameters:**
- `muted`: Mute state

#### getMute

Get mute state.

```dart
Future<bool> getMute()
```

**Returns:** Current mute state

### Streams

#### deviceStateStream

Stream of device state changes.

```dart
Stream<Uac2State> get deviceStateStream
```

**Example:**

```dart
uac2Service.deviceStateStream.listen((state) {
  switch (state) {
    case Uac2State.idle:
      print('Idle');
      break;
    case Uac2State.connecting:
      print('Connecting...');
      break;
    case Uac2State.connected:
      print('Connected');
      break;
    case Uac2State.streaming:
      print('Streaming');
      break;
    case Uac2State.error:
      print('Error');
      break;
  }
});
```

#### hotplugStream

Stream of device connection/disconnection events.

```dart
Stream<Uac2HotplugEvent> get hotplugStream
```

**Example:**

```dart
uac2Service.hotplugStream.listen((event) {
  if (event.connected) {
    print('Device connected: ${event.deviceId}');
  } else {
    print('Device disconnected: ${event.deviceId}');
  }
});
```

## Data Models

### Uac2DeviceInfo

Device information.

```dart
class Uac2DeviceInfo {
  final String id;
  final int vendorId;
  final int productId;
  final String manufacturer;
  final String product;
  final String serial;
  final Uac2Capabilities capabilities;
}
```

### Uac2Capabilities

Device capabilities.

```dart
class Uac2Capabilities {
  final List<Uac2AudioFormat> supportedFormats;
  final int maxSampleRate;
  final int maxBitDepth;
  final int maxChannels;
  final bool hasVolumeControl;
  final bool hasMuteControl;
}
```

### Uac2AudioFormat

Audio format specification.

```dart
class Uac2AudioFormat {
  final int sampleRate;
  final int bitDepth;
  final int channels;
  
  const Uac2AudioFormat({
    required this.sampleRate,
    required this.bitDepth,
    required this.channels,
  });
}
```

### Uac2StreamConfig

Stream configuration.

```dart
class Uac2StreamConfig {
  final Uac2AudioFormat format;
  final int bufferSize;
  final int numBuffers;
  
  const Uac2StreamConfig({
    required this.format,
    this.bufferSize = 2048,
    this.numBuffers = 4,
  });
}
```

### Uac2State

Device connection state.

```dart
enum Uac2State {
  idle,
  connecting,
  connected,
  streaming,
  error,
}
```

### Uac2HotplugEvent

Hot-plug event.

```dart
class Uac2HotplugEvent {
  final String deviceId;
  final bool connected;
  
  const Uac2HotplugEvent({
    required this.deviceId,
    required this.connected,
  });
}
```

### Uac2Exception

UAC 2.0 exception.

```dart
class Uac2Exception implements Exception {
  final String message;
  final Uac2ErrorCode code;
  
  const Uac2Exception(this.message, this.code);
}
```

### Uac2ErrorCode

Error codes.

```dart
enum Uac2ErrorCode {
  deviceNotFound,
  deviceBusy,
  permissionDenied,
  connectionFailed,
  transferFailed,
  unsupportedFormat,
  unknown,
}
```

## Riverpod Providers

### uac2DevicesProvider

Provider for device list.

```dart
final uac2DevicesProvider = StreamProvider<List<Uac2DeviceInfo>>((ref) {
  return uac2Service.deviceListStream;
});
```

**Usage:**

```dart
final devicesAsync = ref.watch(uac2DevicesProvider);
devicesAsync.when(
  data: (devices) => DeviceList(devices: devices),
  loading: () => CircularProgressIndicator(),
  error: (err, stack) => Text('Error: $err'),
);
```

### uac2StateProvider

Provider for device state.

```dart
final uac2StateProvider = StreamProvider<Uac2State>((ref) {
  return uac2Service.deviceStateStream;
});
```

### currentUac2DeviceProvider

Provider for currently connected device.

```dart
final currentUac2DeviceProvider = StateProvider<Uac2DeviceInfo?>((ref) {
  return null;
});
```

## Uac2PreferencesService

Service for UAC 2.0 preferences.

**Location:** `lib/services/uac2_preferences_service.dart`

### Methods

#### getSelectedDeviceId

Get saved device ID.

```dart
Future<String?> getSelectedDeviceId()
```

#### setSelectedDeviceId

Save device ID.

```dart
Future<void> setSelectedDeviceId(String deviceId)
```

#### getAutoConnect

Get auto-connect preference.

```dart
Future<bool> getAutoConnect()
```

#### setAutoConnect

Set auto-connect preference.

```dart
Future<void> setAutoConnect(bool enabled)
```

#### getPreferredFormat

Get preferred audio format.

```dart
Future<Uac2AudioFormat?> getPreferredFormat()
```

#### setPreferredFormat

Set preferred audio format.

```dart
Future<void> setPreferredFormat(Uac2AudioFormat format)
```

## Widgets

### Uac2DeviceSelector

Device selection widget.

**Location:** `lib/widgets/uac2/uac2_device_selector.dart`

```dart
Uac2DeviceSelector({
  required List<Uac2DeviceInfo> devices,
  Uac2DeviceInfo? selectedDevice,
  required ValueChanged<Uac2DeviceInfo> onDeviceSelected,
  VoidCallback? onRefresh,
})
```

### Uac2StatusIndicator

Status indicator widget.

**Location:** `lib/widgets/uac2/uac2_status_indicator.dart`

```dart
Uac2StatusIndicator({
  required Uac2State state,
  Uac2DeviceInfo? device,
  VoidCallback? onTap,
})
```

### Uac2DeviceCapabilities

Capabilities display widget.

**Location:** `lib/widgets/uac2/uac2_device_capabilities.dart`

```dart
Uac2DeviceCapabilities({
  required Uac2Capabilities capabilities,
})
```

### Uac2PlayerStatus

Player integration widget.

**Location:** `lib/widgets/uac2/uac2_player_status.dart`

```dart
Uac2PlayerStatus({
  required Uac2State state,
  Uac2AudioFormat? currentFormat,
})
```

## Example Usage

### Basic Device Connection

```dart
// Enumerate devices
final devices = await uac2Service.enumerateDevices();

// Select first device
if (devices.isNotEmpty) {
  final device = devices.first;
  
  // Connect
  await uac2Service.connectDevice(device.id);
  
  // Get capabilities
  final caps = await uac2Service.getDeviceCapabilities(device.id);
  
  // Start streaming with best format
  final format = caps.supportedFormats.first;
  final config = Uac2StreamConfig(format: format);
  await uac2Service.startStream(config);
}
```

### With Riverpod

```dart
class DeviceListScreen extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devicesAsync = ref.watch(uac2DevicesProvider);
    
    return devicesAsync.when(
      data: (devices) => ListView.builder(
        itemCount: devices.length,
        itemBuilder: (context, index) {
          final device = devices[index];
          return ListTile(
            title: Text('${device.manufacturer} ${device.product}'),
            onTap: () async {
              await uac2Service.connectDevice(device.id);
            },
          );
        },
      ),
      loading: () => CircularProgressIndicator(),
      error: (err, stack) => Text('Error: $err'),
    );
  }
}
```

## Related Documentation

- [Rust API](rust-api.md)
- [FFI Bridge](ffi-bridge.md)
- [Examples](../examples/basic-usage.md)
