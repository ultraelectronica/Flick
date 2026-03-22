import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flick/src/rust/api/uac2_api.dart' as rust_uac2;
import 'package:flick/services/uac2_preferences_service.dart';

enum Uac2State {
  idle,
  connecting,
  connected,
  streaming,
  error,
}

class Uac2AudioFormat {
  final int sampleRate;
  final int bitDepth;
  final int channels;

  const Uac2AudioFormat({
    required this.sampleRate,
    required this.bitDepth,
    required this.channels,
  });

  Map<String, dynamic> toJson() => {
        'sampleRate': sampleRate,
        'bitDepth': bitDepth,
        'channels': channels,
      };

  factory Uac2AudioFormat.fromJson(Map<String, dynamic> json) {
    return Uac2AudioFormat(
      sampleRate: json['sampleRate'] as int,
      bitDepth: json['bitDepth'] as int,
      channels: json['channels'] as int,
    );
  }
}

class Uac2DeviceCapabilities {
  final List<int> supportedSampleRates;
  final List<int> supportedBitDepths;
  final List<int> supportedChannels;
  final String deviceType;

  const Uac2DeviceCapabilities({
    required this.supportedSampleRates,
    required this.supportedBitDepths,
    required this.supportedChannels,
    required this.deviceType,
  });
}

class Uac2DeviceStatus {
  final Uac2DeviceInfo device;
  final Uac2State state;
  final String? errorMessage;
  final Uac2AudioFormat? currentFormat;

  const Uac2DeviceStatus({
    required this.device,
    required this.state,
    this.errorMessage,
    this.currentFormat,
  });

  Uac2DeviceStatus copyWith({
    Uac2DeviceInfo? device,
    Uac2State? state,
    String? errorMessage,
    Uac2AudioFormat? currentFormat,
  }) {
    return Uac2DeviceStatus(
      device: device ?? this.device,
      state: state ?? this.state,
      errorMessage: errorMessage ?? this.errorMessage,
      currentFormat: currentFormat ?? this.currentFormat,
    );
  }
}

class Uac2Service {
  Uac2Service._();

  static final Uac2Service instance = Uac2Service._();

  static const _channel = MethodChannel('com.ultraelectronica.flick/uac2');

  final _preferencesService = Uac2PreferencesService();
  Uac2DeviceStatus? _currentDeviceStatus;
  final List<ValueChanged<Uac2DeviceStatus?>> _statusListeners = [];

  Uac2DeviceStatus? get currentDeviceStatus => _currentDeviceStatus;

  bool get isAvailable {
    if (Platform.isAndroid) return true;
    return rust_uac2.uac2IsAvailable();
  }

  void addStatusListener(ValueChanged<Uac2DeviceStatus?> listener) {
    _statusListeners.add(listener);
  }

  void removeStatusListener(ValueChanged<Uac2DeviceStatus?> listener) {
    _statusListeners.remove(listener);
  }

  void _notifyStatusListeners() {
    for (final listener in _statusListeners) {
      listener(_currentDeviceStatus);
    }
  }

  Future<void> initialize() async {
    final autoConnect = await _preferencesService.getAutoConnect();
    if (!autoConnect) return;

    final savedDevice = await _preferencesService.loadSelectedDevice();
    if (savedDevice == null) return;

    final devices = await listDevices();
    final matchingDevice = devices.firstWhere(
      (d) =>
          d.vendorId == savedDevice.vendorId &&
          d.productId == savedDevice.productId &&
          d.serial == savedDevice.serial,
      orElse: () => savedDevice,
    );

    await selectDevice(matchingDevice);
  }

  Future<List<Uac2DeviceInfo>> listDevices() async {
    if (Platform.isAndroid) return _listDevicesAndroid();
    if (!rust_uac2.uac2IsAvailable()) return [];
    try {
      return rust_uac2.uac2ListDevices();
    } catch (e) {
      debugPrint('Uac2Service.listDevices failed: $e');
      return [];
    }
  }

  Future<List<Uac2DeviceInfo>> _listDevicesAndroid() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('listDevices');
      if (raw == null) return [];
      return raw.map((e) {
        final m = Map<String, dynamic>.from(e as Map<dynamic, dynamic>);
        final deviceName = m['deviceName'] as String?;
        return Uac2DeviceInfo(
          vendorId: (m['vendorId'] as num?)?.toInt() ?? 0,
          productId: (m['productId'] as num?)?.toInt() ?? 0,
          serial: m['serial'] as String? ?? deviceName,
          productName: m['productName'] as String? ?? 'USB Audio Device',
          manufacturer: m['manufacturer'] as String? ?? '',
        );
      }).toList();
    } catch (e) {
      debugPrint('Uac2Service.listDevices (Android) failed: $e');
      return [];
    }
  }

  Future<bool> hasPermission(String deviceName) async {
    if (!Platform.isAndroid) return true;
    try {
      final result = await _channel.invokeMethod<bool>(
        'hasPermission',
        {'deviceName': deviceName},
      );
      return result ?? false;
    } catch (e) {
      debugPrint('Uac2Service.hasPermission failed: $e');
      return false;
    }
  }

  Future<bool> requestPermission(String deviceName) async {
    if (!Platform.isAndroid) return true;
    try {
      final result = await _channel.invokeMethod<bool>(
        'requestPermission',
        {'deviceName': deviceName},
      );
      return result ?? false;
    } catch (e) {
      debugPrint('Uac2Service.requestPermission failed: $e');
      return false;
    }
  }

  Future<Uac2DeviceCapabilities?> getDeviceCapabilities(
    Uac2DeviceInfo device,
  ) async {
    if (Platform.isAndroid) return null;
    if (!rust_uac2.uac2IsAvailable()) return null;
    try {
      return const Uac2DeviceCapabilities(
        supportedSampleRates: [44100, 48000, 96000, 192000],
        supportedBitDepths: [16, 24, 32],
        supportedChannels: [2],
        deviceType: 'DAC',
      );
    } catch (e) {
      debugPrint('Uac2Service.getDeviceCapabilities failed: $e');
      return null;
    }
  }

  Future<bool> selectDevice(Uac2DeviceInfo device) async {
    try {
      _updateStatus(
        Uac2DeviceStatus(device: device, state: Uac2State.connecting),
      );

      if (Platform.isAndroid) {
        final hasPermission = await this.hasPermission(device.serial ?? '');
        if (!hasPermission) {
          final granted = await requestPermission(device.serial ?? '');
          if (!granted) {
            _updateStatus(
              Uac2DeviceStatus(
                device: device,
                state: Uac2State.error,
                errorMessage: 'Permission denied',
              ),
            );
            return false;
          }
        }
      }

      if (!rust_uac2.uac2IsAvailable()) {
        _updateStatus(
          Uac2DeviceStatus(
            device: device,
            state: Uac2State.error,
            errorMessage: 'UAC2 not available',
          ),
        );
        return false;
      }

      await _preferencesService.saveSelectedDevice(device);
      _updateStatus(
        Uac2DeviceStatus(device: device, state: Uac2State.connected),
      );
      return true;
    } catch (e) {
      debugPrint('Uac2Service.selectDevice failed: $e');
      _updateStatus(
        Uac2DeviceStatus(
          device: device,
          state: Uac2State.error,
          errorMessage: e.toString(),
        ),
      );
      return false;
    }
  }

  Future<bool> startStreaming(Uac2AudioFormat format) async {
    if (_currentDeviceStatus == null) return false;
    if (_currentDeviceStatus!.state != Uac2State.connected) return false;

    try {
      if (!rust_uac2.uac2IsAvailable()) return false;

      _updateStatus(
        _currentDeviceStatus!.copyWith(
          state: Uac2State.streaming,
          currentFormat: format,
        ),
      );
      return true;
    } catch (e) {
      debugPrint('Uac2Service.startStreaming failed: $e');
      _updateStatus(
        _currentDeviceStatus!.copyWith(
          state: Uac2State.error,
          errorMessage: e.toString(),
        ),
      );
      return false;
    }
  }

  Future<bool> stopStreaming() async {
    if (_currentDeviceStatus == null) return false;

    try {
      if (!rust_uac2.uac2IsAvailable()) return false;

      _updateStatus(
        _currentDeviceStatus!.copyWith(
          state: Uac2State.connected,
          currentFormat: null,
        ),
      );
      return true;
    } catch (e) {
      debugPrint('Uac2Service.stopStreaming failed: $e');
      return false;
    }
  }

  Future<void> disconnect() async {
    if (_currentDeviceStatus == null) return;

    try {
      if (rust_uac2.uac2IsAvailable()) {
      }
      await _preferencesService.clearSelectedDevice();
    } catch (e) {
      debugPrint('Uac2Service.disconnect failed: $e');
    } finally {
      _updateStatus(null);
    }
  }

  void _updateStatus(Uac2DeviceStatus? status) {
    _currentDeviceStatus = status;
    _notifyStatusListeners();
  }
}

typedef Uac2DeviceInfo = rust_uac2.Uac2DeviceInfo;
