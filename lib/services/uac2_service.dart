import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flick/models/song.dart';
import 'package:flick/src/rust/api/uac2_api.dart' as rust_uac2;
import 'package:flick/services/uac2_preferences_service.dart';
import 'package:flick/services/uac2_exception.dart';

const Object _unset = Object();

enum Uac2State { idle, connecting, connected, streaming, error }

enum Uac2RouteType { internalDac, externalUsb, wired, bluetooth, dock, unknown }

enum Uac2VolumeMode { system, hardware, unavailable }

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
  final Uac2RouteType routeType;
  final String? routeLabel;
  final bool isExternalRoute;
  final Uac2VolumeMode volumeMode;
  final bool hasVolumeControl;
  final double? volume;
  final bool? muted;

  const Uac2DeviceStatus({
    required this.device,
    required this.state,
    this.errorMessage,
    this.currentFormat,
    this.routeType = Uac2RouteType.unknown,
    this.routeLabel,
    this.isExternalRoute = false,
    this.volumeMode = Uac2VolumeMode.unavailable,
    this.hasVolumeControl = false,
    this.volume,
    this.muted,
  });

  Uac2DeviceStatus copyWith({
    Uac2DeviceInfo? device,
    Uac2State? state,
    Object? errorMessage = _unset,
    Object? currentFormat = _unset,
    Uac2RouteType? routeType,
    Object? routeLabel = _unset,
    bool? isExternalRoute,
    Uac2VolumeMode? volumeMode,
    bool? hasVolumeControl,
    Object? volume = _unset,
    Object? muted = _unset,
  }) {
    return Uac2DeviceStatus(
      device: device ?? this.device,
      state: state ?? this.state,
      errorMessage: identical(errorMessage, _unset)
          ? this.errorMessage
          : errorMessage as String?,
      currentFormat: identical(currentFormat, _unset)
          ? this.currentFormat
          : currentFormat as Uac2AudioFormat?,
      routeType: routeType ?? this.routeType,
      routeLabel: identical(routeLabel, _unset)
          ? this.routeLabel
          : routeLabel as String?,
      isExternalRoute: isExternalRoute ?? this.isExternalRoute,
      volumeMode: volumeMode ?? this.volumeMode,
      hasVolumeControl: hasVolumeControl ?? this.hasVolumeControl,
      volume: identical(volume, _unset) ? this.volume : volume as double?,
      muted: identical(muted, _unset) ? this.muted : muted as bool?,
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
  bool _androidChannelConfigured = false;
  Uac2AudioFormat? _lastKnownFormat;
  bool _lastKnownIsPlaying = false;
  bool _lastKnownHasSong = false;

  Uac2DeviceStatus? get currentDeviceStatus => _currentDeviceStatus;

  bool get isAvailable {
    if (Platform.isAndroid) return true;
    return rust_uac2.uac2IsAvailable();
  }

  bool get supportsTransferStats {
    if (Platform.isAndroid) return false;
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
    if (Platform.isAndroid) {
      _configureAndroidChannel();
    }

    final autoConnect = await _preferencesService.getAutoConnect();
    final savedDevice = await _preferencesService.loadSelectedDevice();
    if (!autoConnect || savedDevice == null) return;

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

  void _configureAndroidChannel() {
    if (_androidChannelConfigured) return;
    _androidChannelConfigured = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onDeviceAttached':
        case 'onDeviceDetached':
          if (_currentDeviceStatus != null || _lastKnownHasSong) {
            await _refreshAndroidRouteStatus();
          }
          return;
        default:
          return;
      }
    });
  }

  Future<List<Uac2DeviceInfo>> listDevices() async {
    if (Platform.isAndroid) return _listDevicesAndroid();
    if (!rust_uac2.uac2IsAvailable()) return [];
    try {
      return rust_uac2.uac2ListDevices();
    } catch (e) {
      debugPrint('Uac2Service.listDevices failed: $e');
      throw Uac2Exception.fromMessage(e.toString());
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
          serial: m['serial'] as String?,
          productName: m['productName'] as String? ?? 'USB Audio Device',
          manufacturer: m['manufacturer'] as String? ?? '',
          deviceName: deviceName,
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
      final result = await _channel.invokeMethod<bool>('hasPermission', {
        'deviceName': deviceName,
      });
      return result ?? false;
    } catch (e) {
      debugPrint('Uac2Service.hasPermission failed: $e');
      return false;
    }
  }

  Future<bool> requestPermission(String deviceName) async {
    if (!Platform.isAndroid) return true;
    try {
      final result = await _channel.invokeMethod<bool>('requestPermission', {
        'deviceName': deviceName,
      });
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
        final deviceIdentifier = device.deviceName ?? device.serial ?? '';
        final hasPermission = await this.hasPermission(deviceIdentifier);
        if (!hasPermission) {
          final granted = await requestPermission(deviceIdentifier);
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

        // On Android, we use native USB implementation, not Rust
        await _preferencesService.saveSelectedDevice(device);
        await _refreshAndroidRouteStatus(
          preferredDevice: device,
          formatOverride: _lastKnownFormat,
          isPlaying: _lastKnownIsPlaying,
          hasActiveSong: _lastKnownHasSong,
        );
        return true;
      }

      // For non-Android platforms, check if Rust UAC2 is available
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
      if (Platform.isAndroid) {
        _lastKnownFormat = format;
        _lastKnownIsPlaying = true;
        _lastKnownHasSong = true;
        await _refreshAndroidRouteStatus(
          formatOverride: format,
          isPlaying: true,
          hasActiveSong: true,
        );
        return true;
      }

      if (!rust_uac2.uac2IsAvailable()) {
        return false;
      }

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
      if (Platform.isAndroid) {
        _lastKnownFormat = null;
        _lastKnownIsPlaying = false;
        _lastKnownHasSong = false;
        await _refreshAndroidRouteStatus(
          formatOverride: null,
          isPlaying: false,
          hasActiveSong: false,
        );
        return true;
      }

      if (!rust_uac2.uac2IsAvailable()) {
        return false;
      }

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
      if (!Platform.isAndroid && rust_uac2.uac2IsAvailable()) {
        await rust_uac2.uac2Disconnect();
      }
      await _preferencesService.clearSelectedDevice();
    } catch (e) {
      debugPrint('Uac2Service.disconnect failed: $e');
    } finally {
      if (Platform.isAndroid) {
        await _refreshAndroidRouteStatus(
          formatOverride: _lastKnownFormat,
          isPlaying: _lastKnownIsPlaying,
          hasActiveSong: _lastKnownHasSong,
          preferredDevice: null,
        );
      } else {
        _updateStatus(null);
      }
    }
  }

  Future<bool> setVolume(double volume) async {
    if (_currentDeviceStatus == null) return false;
    if (volume < 0.0 || volume > 1.0) return false;

    try {
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod<bool>('setRouteVolume', {
          'volume': volume,
        });
        if (result == true) {
          await _refreshAndroidRouteStatus();
        }
        return result ?? false;
      }
      if (!rust_uac2.uac2IsAvailable()) return false;
      await rust_uac2.uac2SetVolume(volume: volume);
      return true;
    } catch (e) {
      debugPrint('Uac2Service.setVolume failed: $e');
      return false;
    }
  }

  Future<double?> getVolume() async {
    if (_currentDeviceStatus == null) return null;

    try {
      if (Platform.isAndroid) {
        final volume = await _channel.invokeMethod<double>('getRouteVolume');
        if (volume != null) {
          _updateStatus(_currentDeviceStatus!.copyWith(volume: volume));
        }
        return volume ?? _currentDeviceStatus?.volume;
      }
      if (!rust_uac2.uac2IsAvailable()) return null;
      return rust_uac2.uac2GetVolume();
    } catch (e) {
      debugPrint('Uac2Service.getVolume failed: $e');
      return null;
    }
  }

  Future<bool> setMute(bool muted) async {
    if (_currentDeviceStatus == null) return false;

    try {
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod<bool>('setRouteMuted', {
          'muted': muted,
        });
        if (result == true) {
          await _refreshAndroidRouteStatus();
        }
        return result ?? false;
      }
      if (!rust_uac2.uac2IsAvailable()) return false;
      await rust_uac2.uac2SetMute(muted: muted);
      return true;
    } catch (e) {
      debugPrint('Uac2Service.setMute failed: $e');
      return false;
    }
  }

  Future<bool?> getMute() async {
    if (_currentDeviceStatus == null) return null;

    try {
      if (Platform.isAndroid) {
        final muted = await _channel.invokeMethod<bool>('getRouteMuted');
        if (muted != null) {
          _updateStatus(_currentDeviceStatus!.copyWith(muted: muted));
        }
        return muted ?? _currentDeviceStatus?.muted;
      }
      if (!rust_uac2.uac2IsAvailable()) return null;
      return rust_uac2.uac2GetMute();
    } catch (e) {
      debugPrint('Uac2Service.getMute failed: $e');
      return null;
    }
  }

  Future<Uac2VolumeRange?> getVolumeRange() async {
    if (_currentDeviceStatus == null) return null;

    try {
      if (Platform.isAndroid) {
        return null;
      }
      if (!rust_uac2.uac2IsAvailable()) return null;
      return rust_uac2.uac2GetVolumeRange();
    } catch (e) {
      debugPrint('Uac2Service.getVolumeRange failed: $e');
      return null;
    }
  }

  Future<bool> setSamplingFrequency(int frequency) async {
    if (_currentDeviceStatus == null) return false;

    try {
      if (Platform.isAndroid) {
        return false;
      }
      if (!rust_uac2.uac2IsAvailable()) return false;
      await rust_uac2.uac2SetSamplingFrequency(frequency: frequency);
      return true;
    } catch (e) {
      debugPrint('Uac2Service.setSamplingFrequency failed: $e');
      return false;
    }
  }

  Future<int?> getSamplingFrequency() async {
    if (_currentDeviceStatus == null) return null;

    try {
      if (Platform.isAndroid) {
        return null;
      }
      if (!rust_uac2.uac2IsAvailable()) return null;
      return rust_uac2.uac2GetSamplingFrequency();
    } catch (e) {
      debugPrint('Uac2Service.getSamplingFrequency failed: $e');
      return null;
    }
  }

  Future<Uac2TransferStats?> getTransferStats() async {
    if (_currentDeviceStatus == null) return null;

    try {
      if (!supportsTransferStats) return null;
      return rust_uac2.uac2GetTransferStats();
    } catch (e) {
      debugPrint('Uac2Service.getTransferStats failed: $e');
      return null;
    }
  }

  Future<bool> resetTransferStats() async {
    if (_currentDeviceStatus == null) return false;

    try {
      if (!supportsTransferStats) return false;
      await rust_uac2.uac2ResetTransferStats();
      return true;
    } catch (e) {
      debugPrint('Uac2Service.resetTransferStats failed: $e');
      return false;
    }
  }

  Future<Uac2PipelineInfo?> getPipelineInfo() async {
    if (_currentDeviceStatus == null) return null;

    try {
      if (Platform.isAndroid) {
        return null;
      }
      if (!rust_uac2.uac2IsAvailable()) return null;
      return rust_uac2.uac2GetPipelineInfo();
    } catch (e) {
      debugPrint('Uac2Service.getPipelineInfo failed: $e');
      return null;
    }
  }

  Future<Uac2ConnectionState?> getConnectionState() async {
    try {
      if (Platform.isAndroid) {
        return null;
      }
      if (!rust_uac2.uac2IsAvailable()) return null;
      return rust_uac2.uac2GetConnectionState();
    } catch (e) {
      debugPrint('Uac2Service.getConnectionState failed: $e');
      return null;
    }
  }

  Future<bool> setAutoReconnect(bool enabled) async {
    try {
      if (Platform.isAndroid) {
        return false;
      }
      if (!rust_uac2.uac2IsAvailable()) return false;
      await rust_uac2.uac2SetAutoReconnect(enabled: enabled);
      return true;
    } catch (e) {
      debugPrint('Uac2Service.setAutoReconnect failed: $e');
      return false;
    }
  }

  Future<bool> attemptReconnect() async {
    try {
      if (Platform.isAndroid) {
        return false;
      }
      if (!rust_uac2.uac2IsAvailable()) return false;
      return rust_uac2.uac2AttemptReconnect();
    } catch (e) {
      debugPrint('Uac2Service.attemptReconnect failed: $e');
      return false;
    }
  }

  Future<Uac2FallbackInfo?> getFallbackInfo() async {
    try {
      if (Platform.isAndroid) {
        return null;
      }
      if (!rust_uac2.uac2IsAvailable()) return null;
      return rust_uac2.uac2GetFallbackInfo();
    } catch (e) {
      debugPrint('Uac2Service.getFallbackInfo failed: $e');
      return null;
    }
  }

  Future<bool> activateFallback() async {
    try {
      if (Platform.isAndroid) {
        return false;
      }
      if (!rust_uac2.uac2IsAvailable()) return false;
      return rust_uac2.uac2ActivateFallback();
    } catch (e) {
      debugPrint('Uac2Service.activateFallback failed: $e');
      return false;
    }
  }

  Future<bool> deactivateFallback() async {
    try {
      if (Platform.isAndroid) {
        return false;
      }
      if (!rust_uac2.uac2IsAvailable()) return false;
      await rust_uac2.uac2DeactivateFallback();
      return true;
    } catch (e) {
      debugPrint('Uac2Service.deactivateFallback failed: $e');
      return false;
    }
  }

  Future<void> syncPlaybackStatus({
    Song? song,
    required bool isPlaying,
    Uac2AudioFormat? formatOverride,
  }) async {
    _lastKnownFormat = formatOverride;
    _lastKnownIsPlaying = isPlaying;
    _lastKnownHasSong = song != null;

    if (Platform.isAndroid) {
      await _refreshAndroidRouteStatus(
        formatOverride: formatOverride,
        isPlaying: isPlaying,
        hasActiveSong: song != null,
      );
      return;
    }

    if (_currentDeviceStatus == null) return;
    _updateStatus(
      _currentDeviceStatus!.copyWith(
        state: isPlaying ? Uac2State.streaming : Uac2State.connected,
        currentFormat: formatOverride,
        errorMessage: null,
      ),
    );
  }

  Future<void> _refreshAndroidRouteStatus({
    Uac2DeviceInfo? preferredDevice,
    Uac2AudioFormat? formatOverride,
    bool? isPlaying,
    bool? hasActiveSong,
  }) async {
    final resolvedPreferredDevice = await _resolvePreferredAndroidDevice(
      preferredDevice,
    );
    final routeStatus = await _getAndroidRouteStatus(
      preferredDevice: resolvedPreferredDevice,
    );
    final effectiveFormat = formatOverride ?? _lastKnownFormat;
    final effectiveIsPlaying = isPlaying ?? _lastKnownIsPlaying;
    final effectiveHasSong = hasActiveSong ?? _lastKnownHasSong;
    final prefersExternalDevice =
        resolvedPreferredDevice != null &&
        (resolvedPreferredDevice.vendorId != 0 ||
            resolvedPreferredDevice.productId != 0 ||
            (resolvedPreferredDevice.deviceName?.isNotEmpty ?? false));

    if (routeStatus == null) {
      if (!effectiveHasSong && !effectiveIsPlaying) {
        _updateStatus(null);
        return;
      }

      final fallbackDevice =
          resolvedPreferredDevice ??
          _currentDeviceStatus?.device ??
          _buildSyntheticAndroidDevice(
            routeType: Uac2RouteType.unknown,
            routeLabel: 'Audio route unavailable',
          );
      _updateStatus(
        Uac2DeviceStatus(
          device: fallbackDevice,
          state: Uac2State.error,
          errorMessage: 'Audio route unavailable',
          currentFormat: effectiveFormat,
        ),
      );
      return;
    }

    final routeType = _routeTypeFromString(routeStatus['routeType'] as String?);
    final routeLabel = routeStatus['routeLabel'] as String?;
    final isExternal = routeStatus['isExternal'] == true;
    final volumeMode = _volumeModeFromString(
      routeStatus['volumeMode'] as String?,
    );
    final hasVolumeControl = routeStatus['hasVolumeControl'] == true;
    final volume = (routeStatus['volume'] as num?)?.toDouble();
    final muted = routeStatus['muted'] as bool?;

    if (!effectiveHasSong &&
        !effectiveIsPlaying &&
        !isExternal &&
        !prefersExternalDevice) {
      _updateStatus(null);
      return;
    }

    if (!effectiveHasSong &&
        !effectiveIsPlaying &&
        prefersExternalDevice &&
        routeType != Uac2RouteType.externalUsb) {
      _updateStatus(
        Uac2DeviceStatus(
          device: resolvedPreferredDevice,
          state: Uac2State.error,
          errorMessage: 'Selected USB DAC not detected',
          currentFormat: effectiveFormat,
          routeType: routeType,
          routeLabel: routeLabel,
          isExternalRoute: false,
          volumeMode: volumeMode,
          hasVolumeControl: hasVolumeControl,
          volume: volume,
          muted: muted,
        ),
      );
      return;
    }

    final routeDevice = _deviceFromAndroidRoute(
      routeStatus,
      preferredDevice: routeType == Uac2RouteType.externalUsb
          ? resolvedPreferredDevice
          : null,
    );

    _updateStatus(
      Uac2DeviceStatus(
        device: routeDevice,
        state: effectiveIsPlaying ? Uac2State.streaming : Uac2State.connected,
        errorMessage: null,
        currentFormat: effectiveFormat,
        routeType: routeType,
        routeLabel: routeLabel,
        isExternalRoute: isExternal,
        volumeMode: volumeMode,
        hasVolumeControl: hasVolumeControl,
        volume: volume,
        muted: muted,
      ),
    );
  }

  Future<Uac2DeviceInfo?> _resolvePreferredAndroidDevice(
    Uac2DeviceInfo? preferredDevice,
  ) async {
    if (preferredDevice != null &&
        (preferredDevice.vendorId != 0 ||
            preferredDevice.productId != 0 ||
            (preferredDevice.deviceName?.isNotEmpty ?? false))) {
      return preferredDevice;
    }

    final currentDevice = _currentDeviceStatus;
    if (currentDevice != null && currentDevice.isExternalRoute) {
      return currentDevice.device;
    }

    return _preferencesService.loadSelectedDevice();
  }

  Future<Map<String, dynamic>?> _getAndroidRouteStatus({
    Uac2DeviceInfo? preferredDevice,
  }) async {
    try {
      final raw = await _channel
          .invokeMapMethod<dynamic, dynamic>('getRouteStatus', {
            'deviceName': preferredDevice?.deviceName,
            'productName': preferredDevice?.productName,
            'vendorId': preferredDevice?.vendorId,
            'productId': preferredDevice?.productId,
            'serial': preferredDevice?.serial,
          });
      if (raw == null) return null;
      return raw.map((key, value) => MapEntry(key.toString(), value));
    } catch (e) {
      debugPrint('Uac2Service._getAndroidRouteStatus failed: $e');
      return null;
    }
  }

  Uac2DeviceInfo _deviceFromAndroidRoute(
    Map<String, dynamic> routeStatus, {
    Uac2DeviceInfo? preferredDevice,
  }) {
    final routeType = _routeTypeFromString(routeStatus['routeType'] as String?);
    final productName =
        routeStatus['productName'] as String? ??
        routeStatus['routeLabel'] as String? ??
        preferredDevice?.productName ??
        _defaultProductNameForRoute(routeType);

    return Uac2DeviceInfo(
      vendorId:
          (routeStatus['vendorId'] as num?)?.toInt() ??
          preferredDevice?.vendorId ??
          0,
      productId:
          (routeStatus['productId'] as num?)?.toInt() ??
          preferredDevice?.productId ??
          0,
      serial:
          routeStatus['serial'] as String? ??
          preferredDevice?.serial ??
          routeStatus['deviceName'] as String?,
      productName: productName,
      manufacturer:
          routeStatus['manufacturer'] as String? ??
          preferredDevice?.manufacturer ??
          '',
      deviceName:
          routeStatus['deviceName'] as String? ?? preferredDevice?.deviceName,
    );
  }

  Uac2DeviceInfo _buildSyntheticAndroidDevice({
    required Uac2RouteType routeType,
    String? routeLabel,
  }) {
    return Uac2DeviceInfo(
      vendorId: 0,
      productId: 0,
      serial: null,
      productName: routeLabel ?? _defaultProductNameForRoute(routeType),
      manufacturer: 'Android',
      deviceName: null,
    );
  }

  void _updateStatus(Uac2DeviceStatus? status) {
    _currentDeviceStatus = status;
    _notifyStatusListeners();
  }
}

Uac2RouteType _routeTypeFromString(String? value) {
  switch (value) {
    case 'internal':
      return Uac2RouteType.internalDac;
    case 'usb':
      return Uac2RouteType.externalUsb;
    case 'wired':
      return Uac2RouteType.wired;
    case 'bluetooth':
      return Uac2RouteType.bluetooth;
    case 'dock':
      return Uac2RouteType.dock;
    default:
      return Uac2RouteType.unknown;
  }
}

Uac2VolumeMode _volumeModeFromString(String? value) {
  switch (value) {
    case 'system':
      return Uac2VolumeMode.system;
    case 'hardware':
      return Uac2VolumeMode.hardware;
    default:
      return Uac2VolumeMode.unavailable;
  }
}

String _defaultProductNameForRoute(Uac2RouteType routeType) {
  switch (routeType) {
    case Uac2RouteType.internalDac:
      return 'Device DAC';
    case Uac2RouteType.externalUsb:
      return 'USB DAC';
    case Uac2RouteType.wired:
      return 'Wired Output';
    case Uac2RouteType.bluetooth:
      return 'Bluetooth Output';
    case Uac2RouteType.dock:
      return 'Dock Audio';
    case Uac2RouteType.unknown:
      return 'Audio Output';
  }
}

typedef Uac2DeviceInfo = rust_uac2.Uac2DeviceInfo;
typedef Uac2VolumeRange = rust_uac2.Uac2VolumeRange;
typedef Uac2TransferStats = rust_uac2.Uac2TransferStats;
typedef Uac2PipelineInfo = rust_uac2.Uac2PipelineInfo;
typedef Uac2ConnectionState = rust_uac2.Uac2ConnectionState;
typedef Uac2FallbackInfo = rust_uac2.Uac2FallbackInfo;
