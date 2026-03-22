# Advanced Usage Examples

Complex scenarios and advanced UAC 2.0 features.

## Example 1: Custom Format Negotiation

Implement custom format selection logic.

```dart
class CustomFormatNegotiator {
  /// Select format based on source and preferences
  Uac2AudioFormat negotiate({
    required Uac2AudioFormat sourceFormat,
    required Uac2Capabilities deviceCaps,
    required FormatPreference preference,
  }) {
    switch (preference) {
      case FormatPreference.bitPerfect:
        return _findBitPerfectMatch(sourceFormat, deviceCaps);
        
      case FormatPreference.highestQuality:
        return _findHighestQuality(deviceCaps);
        
      case FormatPreference.lowestLatency:
        return _findLowestLatency(deviceCaps);
        
      case FormatPreference.balanced:
        return _findBalanced(sourceFormat, deviceCaps);
    }
  }
  
  Uac2AudioFormat _findBitPerfectMatch(
    Uac2AudioFormat source,
    Uac2Capabilities caps,
  ) {
    // Try exact match first
    final exact = caps.supportedFormats.firstWhere(
      (f) => f.sampleRate == source.sampleRate &&
             f.bitDepth == source.bitDepth &&
             f.channels == source.channels,
      orElse: () => _findClosestMatch(source, caps),
    );
    return exact;
  }
  
  Uac2AudioFormat _findHighestQuality(Uac2Capabilities caps) {
    return caps.supportedFormats.reduce((a, b) {
      final qualityA = a.sampleRate * a.bitDepth * a.channels;
      final qualityB = b.sampleRate * b.bitDepth * b.channels;
      return qualityA > qualityB ? a : b;
    });
  }
  
  Uac2AudioFormat _findLowestLatency(Uac2Capabilities caps) {
    // Lower sample rates = lower latency
    return caps.supportedFormats.reduce((a, b) {
      return a.sampleRate < b.sampleRate ? a : b;
    });
  }
  
  Uac2AudioFormat _findBalanced(
    Uac2AudioFormat source,
    Uac2Capabilities caps,
  ) {
    // Balance between quality and compatibility
    final candidates = caps.supportedFormats.where((f) {
      return f.sampleRate >= 44100 && f.bitDepth >= 16;
    }).toList();
    
    if (candidates.isEmpty) {
      return caps.supportedFormats.first;
    }
    
    return _findClosestMatch(source, 
      Uac2Capabilities(supportedFormats: candidates));
  }
  
  Uac2AudioFormat _findClosestMatch(
    Uac2AudioFormat source,
    Uac2Capabilities caps,
  ) {
    return caps.supportedFormats.reduce((a, b) {
      final scoreA = _matchScore(source, a);
      final scoreB = _matchScore(source, b);
      return scoreA > scoreB ? a : b;
    });
  }
  
  double _matchScore(Uac2AudioFormat source, Uac2AudioFormat candidate) {
    final sampleRateScore = 1.0 - 
      (source.sampleRate - candidate.sampleRate).abs() / source.sampleRate;
    final bitDepthScore = 1.0 - 
      (source.bitDepth - candidate.bitDepth).abs() / source.bitDepth;
    final channelScore = source.channels == candidate.channels ? 1.0 : 0.5;
    
    return (sampleRateScore + bitDepthScore + channelScore) / 3.0;
  }
}

enum FormatPreference {
  bitPerfect,
  highestQuality,
  lowestLatency,
  balanced,
}
```

## Example 2: Multi-Device Management

Manage multiple UAC 2.0 devices simultaneously.

```dart
class MultiDeviceManager {
  final Map<String, Uac2DeviceInfo> _devices = {};
  String? _activeDeviceId;
  
  Future<void> scanDevices() async {
    final devices = await Uac2Service.instance.enumerateDevices();
    
    _devices.clear();
    for (final device in devices) {
      _devices[device.id] = device;
    }
    
    print('Found ${_devices.length} devices');
  }
  
  Future<void> switchDevice(String deviceId) async {
    if (!_devices.containsKey(deviceId)) {
      throw Exception('Device not found: $deviceId');
    }
    
    // Disconnect current device
    if (_activeDeviceId != null) {
      await Uac2Service.instance.stopStream();
      await Uac2Service.instance.disconnectDevice();
    }
    
    // Connect new device
    await Uac2Service.instance.connectDevice(deviceId);
    
    final caps = await Uac2Service.instance.getDeviceCapabilities(deviceId);
    final format = caps.supportedFormats.first;
    final config = Uac2StreamConfig(format: format);
    
    await Uac2Service.instance.startStream(config);
    
    _activeDeviceId = deviceId;
    print('Switched to device: $deviceId');
  }
  
  Future<void> setPreferredDevice(String deviceId) async {
    await Uac2PreferencesService.instance.setSelectedDeviceId(deviceId);
  }
  
  Future<void> autoConnectPreferred() async {
    final preferredId = 
      await Uac2PreferencesService.instance.getSelectedDeviceId();
    
    if (preferredId != null && _devices.containsKey(preferredId)) {
      await switchDevice(preferredId);
    } else if (_devices.isNotEmpty) {
      // Connect to first available device
      await switchDevice(_devices.keys.first);
    }
  }
  
  List<Uac2DeviceInfo> get availableDevices => _devices.values.toList();
  Uac2DeviceInfo? get activeDevice => 
    _activeDeviceId != null ? _devices[_activeDeviceId] : null;
}
```

## Example 3: Adaptive Buffer Management

Dynamically adjust buffer size based on performance.

```dart
class AdaptiveBufferManager {
  int _currentBufferSize = 2048;
  int _underrunCount = 0;
  int _overrunCount = 0;
  DateTime _lastAdjustment = DateTime.now();
  
  static const int minBufferSize = 512;
  static const int maxBufferSize = 8192;
  static const Duration adjustmentInterval = Duration(seconds: 5);
  
  void reportUnderrun() {
    _underrunCount++;
    _considerAdjustment();
  }
  
  void reportOverrun() {
    _overrunCount++;
    _considerAdjustment();
  }
  
  void _considerAdjustment() {
    final now = DateTime.now();
    if (now.difference(_lastAdjustment) < adjustmentInterval) {
      return;
    }
    
    if (_underrunCount > 3) {
      // Increase buffer size
      _increaseBufferSize();
    } else if (_overrunCount > 3 && _currentBufferSize > minBufferSize) {
      // Decrease buffer size
      _decreaseBufferSize();
    }
    
    _underrunCount = 0;
    _overrunCount = 0;
    _lastAdjustment = now;
  }
  
  void _increaseBufferSize() {
    final newSize = (_currentBufferSize * 1.5).toInt();
    if (newSize <= maxBufferSize) {
      _currentBufferSize = newSize;
      print('Increased buffer size to $_currentBufferSize');
      _reconfigureStream();
    }
  }
  
  void _decreaseBufferSize() {
    final newSize = (_currentBufferSize * 0.75).toInt();
    if (newSize >= minBufferSize) {
      _currentBufferSize = newSize;
      print('Decreased buffer size to $_currentBufferSize');
      _reconfigureStream();
    }
  }
  
  Future<void> _reconfigureStream() async {
    // Stop current stream
    await Uac2Service.instance.stopStream();
    
    // Get current format
    final deviceId = await _getCurrentDeviceId();
    final caps = await Uac2Service.instance.getDeviceCapabilities(deviceId);
    final format = caps.supportedFormats.first;
    
    // Restart with new buffer size
    final config = Uac2StreamConfig(
      format: format,
      bufferSize: _currentBufferSize,
    );
    
    await Uac2Service.instance.startStream(config);
  }
  
  Future<String> _getCurrentDeviceId() async {
    // Implementation depends on your state management
    throw UnimplementedError();
  }
  
  int get currentBufferSize => _currentBufferSize;
  double get latencyMs => (_currentBufferSize / 48000.0) * 1000.0;
}
```

## Example 4: Format Conversion Pipeline

Handle format conversion when needed.

```dart
class FormatConverter {
  /// Convert audio data from source to target format
  List<double> convert({
    required List<double> input,
    required Uac2AudioFormat sourceFormat,
    required Uac2AudioFormat targetFormat,
  }) {
    var output = input;
    
    // Sample rate conversion
    if (sourceFormat.sampleRate != targetFormat.sampleRate) {
      output = _resample(
        output,
        sourceFormat.sampleRate,
        targetFormat.sampleRate,
      );
    }
    
    // Bit depth conversion
    if (sourceFormat.bitDepth != targetFormat.bitDepth) {
      output = _convertBitDepth(
        output,
        sourceFormat.bitDepth,
        targetFormat.bitDepth,
      );
    }
    
    // Channel conversion
    if (sourceFormat.channels != targetFormat.channels) {
      output = _convertChannels(
        output,
        sourceFormat.channels,
        targetFormat.channels,
      );
    }
    
    return output;
  }
  
  List<double> _resample(
    List<double> input,
    int sourceRate,
    int targetRate,
  ) {
    final ratio = targetRate / sourceRate;
    final outputLength = (input.length * ratio).round();
    final output = List<double>.filled(outputLength, 0.0);
    
    for (var i = 0; i < outputLength; i++) {
      final sourceIndex = i / ratio;
      final index = sourceIndex.floor();
      final fraction = sourceIndex - index;
      
      if (index + 1 < input.length) {
        // Linear interpolation
        output[i] = input[index] * (1 - fraction) + 
                    input[index + 1] * fraction;
      } else {
        output[i] = input[index];
      }
    }
    
    return output;
  }
  
  List<double> _convertBitDepth(
    List<double> input,
    int sourceBits,
    int targetBits,
  ) {
    if (sourceBits == targetBits) return input;
    
    final scale = (1 << (targetBits - sourceBits)).toDouble();
    return input.map((sample) => sample * scale).toList();
  }
  
  List<double> _convertChannels(
    List<double> input,
    int sourceChannels,
    int targetChannels,
  ) {
    if (sourceChannels == targetChannels) return input;
    
    if (sourceChannels == 1 && targetChannels == 2) {
      // Mono to stereo: duplicate
      return input.expand((sample) => [sample, sample]).toList();
    } else if (sourceChannels == 2 && targetChannels == 1) {
      // Stereo to mono: average
      final output = <double>[];
      for (var i = 0; i < input.length; i += 2) {
        output.add((input[i] + input[i + 1]) / 2.0);
      }
      return output;
    }
    
    // Other conversions not implemented
    return input;
  }
}
```

## Example 5: Performance Monitoring

Monitor and log performance metrics.

```dart
class PerformanceMonitor {
  final List<double> _latencies = [];
  final List<int> _bufferFills = [];
  int _underruns = 0;
  int _overruns = 0;
  DateTime _startTime = DateTime.now();
  
  void recordLatency(Duration latency) {
    _latencies.add(latency.inMicroseconds / 1000.0);
    
    // Keep only last 100 samples
    if (_latencies.length > 100) {
      _latencies.removeAt(0);
    }
  }
  
  void recordBufferFill(int fillLevel) {
    _bufferFills.add(fillLevel);
    
    if (_bufferFills.length > 100) {
      _bufferFills.removeAt(0);
    }
  }
  
  void recordUnderrun() {
    _underruns++;
  }
  
  void recordOverrun() {
    _overruns++;
  }
  
  PerformanceStats getStats() {
    final avgLatency = _latencies.isEmpty 
      ? 0.0 
      : _latencies.reduce((a, b) => a + b) / _latencies.length;
    
    final maxLatency = _latencies.isEmpty 
      ? 0.0 
      : _latencies.reduce((a, b) => a > b ? a : b);
    
    final avgBufferFill = _bufferFills.isEmpty 
      ? 0 
      : _bufferFills.reduce((a, b) => a + b) ~/ _bufferFills.length;
    
    final uptime = DateTime.now().difference(_startTime);
    
    return PerformanceStats(
      averageLatencyMs: avgLatency,
      maxLatencyMs: maxLatency,
      averageBufferFill: avgBufferFill,
      underrunCount: _underruns,
      overrunCount: _overruns,
      uptime: uptime,
    );
  }
  
  void reset() {
    _latencies.clear();
    _bufferFills.clear();
    _underruns = 0;
    _overruns = 0;
    _startTime = DateTime.now();
  }
  
  void printStats() {
    final stats = getStats();
    print('Performance Statistics:');
    print('  Average latency: ${stats.averageLatencyMs.toStringAsFixed(2)} ms');
    print('  Max latency: ${stats.maxLatencyMs.toStringAsFixed(2)} ms');
    print('  Average buffer fill: ${stats.averageBufferFill}%');
    print('  Underruns: ${stats.underrunCount}');
    print('  Overruns: ${stats.overrunCount}');
    print('  Uptime: ${stats.uptime}');
  }
}

class PerformanceStats {
  final double averageLatencyMs;
  final double maxLatencyMs;
  final int averageBufferFill;
  final int underrunCount;
  final int overrunCount;
  final Duration uptime;
  
  const PerformanceStats({
    required this.averageLatencyMs,
    required this.maxLatencyMs,
    required this.averageBufferFill,
    required this.underrunCount,
    required this.overrunCount,
    required this.uptime,
  });
}
```

## Example 6: Device Profile System

Save and load device-specific profiles.

```dart
class DeviceProfile {
  final String deviceId;
  final Uac2AudioFormat preferredFormat;
  final int bufferSize;
  final double volume;
  final Map<String, dynamic> customSettings;
  
  const DeviceProfile({
    required this.deviceId,
    required this.preferredFormat,
    this.bufferSize = 2048,
    this.volume = 0.8,
    this.customSettings = const {},
  });
  
  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'preferredFormat': {
      'sampleRate': preferredFormat.sampleRate,
      'bitDepth': preferredFormat.bitDepth,
      'channels': preferredFormat.channels,
    },
    'bufferSize': bufferSize,
    'volume': volume,
    'customSettings': customSettings,
  };
  
  factory DeviceProfile.fromJson(Map<String, dynamic> json) {
    final formatJson = json['preferredFormat'] as Map<String, dynamic>;
    return DeviceProfile(
      deviceId: json['deviceId'],
      preferredFormat: Uac2AudioFormat(
        sampleRate: formatJson['sampleRate'],
        bitDepth: formatJson['bitDepth'],
        channels: formatJson['channels'],
      ),
      bufferSize: json['bufferSize'] ?? 2048,
      volume: json['volume'] ?? 0.8,
      customSettings: json['customSettings'] ?? {},
    );
  }
}

class DeviceProfileManager {
  final Map<String, DeviceProfile> _profiles = {};
  
  Future<void> loadProfiles() async {
    // Load from storage
    final prefs = await SharedPreferences.getInstance();
    final profilesJson = prefs.getString('device_profiles');
    
    if (profilesJson != null) {
      final List<dynamic> list = jsonDecode(profilesJson);
      for (final item in list) {
        final profile = DeviceProfile.fromJson(item);
        _profiles[profile.deviceId] = profile;
      }
    }
  }
  
  Future<void> saveProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _profiles.values.map((p) => p.toJson()).toList();
    await prefs.setString('device_profiles', jsonEncode(list));
  }
  
  Future<void> saveProfile(DeviceProfile profile) async {
    _profiles[profile.deviceId] = profile;
    await saveProfiles();
  }
  
  DeviceProfile? getProfile(String deviceId) {
    return _profiles[deviceId];
  }
  
  Future<void> applyProfile(String deviceId) async {
    final profile = getProfile(deviceId);
    if (profile == null) return;
    
    // Apply settings
    final config = Uac2StreamConfig(
      format: profile.preferredFormat,
      bufferSize: profile.bufferSize,
    );
    
    await Uac2Service.instance.startStream(config);
    await Uac2Service.instance.setVolume(profile.volume);
  }
}
```

## Related Documentation

- [Basic Usage](basic-usage.md)
- [API Reference](../api/flutter-api.md)
- [Architecture](../architecture/overview.md)
