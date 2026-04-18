import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/models/song.dart';
import 'package:flick/src/rust/api/audio_api.dart' as rust_audio;
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
  final String? warningMessage;
  final Uac2AudioFormat? currentFormat;
  final Uac2RouteType routeType;
  final String? routeLabel;
  final bool isExternalRoute;
  final Uac2VolumeMode volumeMode;
  final bool hasVolumeControl;
  final bool volumeControlWritable;
  final double? volume;
  final bool? muted;

  const Uac2DeviceStatus({
    required this.device,
    required this.state,
    this.errorMessage,
    this.warningMessage,
    this.currentFormat,
    this.routeType = Uac2RouteType.unknown,
    this.routeLabel,
    this.isExternalRoute = false,
    this.volumeMode = Uac2VolumeMode.unavailable,
    this.hasVolumeControl = false,
    this.volumeControlWritable = true,
    this.volume,
    this.muted,
  });

  Uac2DeviceStatus copyWith({
    Uac2DeviceInfo? device,
    Uac2State? state,
    Object? errorMessage = _unset,
    Object? warningMessage = _unset,
    Object? currentFormat = _unset,
    Uac2RouteType? routeType,
    Object? routeLabel = _unset,
    bool? isExternalRoute,
    Uac2VolumeMode? volumeMode,
    bool? hasVolumeControl,
    bool? volumeControlWritable,
    Object? volume = _unset,
    Object? muted = _unset,
  }) {
    return Uac2DeviceStatus(
      device: device ?? this.device,
      state: state ?? this.state,
      errorMessage: identical(errorMessage, _unset)
          ? this.errorMessage
          : errorMessage as String?,
      warningMessage: identical(warningMessage, _unset)
          ? this.warningMessage
          : warningMessage as String?,
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
      volumeControlWritable:
          volumeControlWritable ?? this.volumeControlWritable,
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
  final ValueNotifier<bool> bitPerfectEnabledNotifier = ValueNotifier(false);
  Uac2DeviceStatus? _currentDeviceStatus;
  final List<ValueChanged<Uac2DeviceStatus?>> _statusListeners = [];
  bool _androidChannelConfigured = false;
  Future<void>? _initializeInFlight;
  Uac2AudioFormat? _lastKnownFormat;
  bool _lastKnownIsPlaying = false;
  bool _lastKnownHasSong = false;
  bool? _lastDirectUsbPlaybackActive;
  int _playbackStatusSyncGeneration = 0;
  Timer? _androidRouteRefreshDebounceTimer;

  Uac2DeviceStatus? get currentDeviceStatus => _currentDeviceStatus;
  Uac2AudioFormat? get lastKnownFormat => _lastKnownFormat;
  bool get isBitPerfectEnabledSync => bitPerfectEnabledNotifier.value;
  bool get shouldFreezeAndroidDirectUsbSessionQueries =>
      _hasFrozenAndroidDirectUsbSession();

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
    final inFlight = _initializeInFlight;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final future = _initializeInternal();
    _initializeInFlight = future;
    try {
      await future;
    } finally {
      _initializeInFlight = null;
    }
  }

  Future<void> _initializeInternal() async {
    if (Platform.isAndroid) {
      _configureAndroidChannel();
      await _refreshAndroidRouteStatus(
        formatOverride: _lastKnownFormat,
        isPlaying: _lastKnownIsPlaying,
        hasActiveSong: _lastKnownHasSong,
      );
    }

    final autoConnect = await _preferencesService.getAutoConnect();
    final bitPerfectEnabled = await _preferencesService.getBitPerfectEnabled();
    bitPerfectEnabledNotifier.value = bitPerfectEnabled;
    final savedDevice = await _preferencesService.loadSelectedDevice();
    if (savedDevice == null) {
      return;
    }

    if (Platform.isAndroid) {
      if (!bitPerfectEnabled) {
        return;
      }
      final matchingDevice = await _resolvePreferredAndroidActivationDevice(
        savedDevice,
      );
      if (matchingDevice == null) {
        return;
      }
      await selectDevice(matchingDevice);
      return;
    }

    if (!autoConnect) {
      return;
    }

    await selectDevice(savedDevice);
  }

  void _configureAndroidChannel() {
    if (_androidChannelConfigured) return;
    _androidChannelConfigured = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onDeviceAttached':
        case 'onDeviceDetached':
          _scheduleAndroidRouteRefresh();
          return;
        case 'onVolumeChanged':
          final args = call.arguments as Map<dynamic, dynamic>?;
          if (args == null) return;
          final volume = (args['volume'] as num?)?.toDouble();
          final muted = args['muted'] as bool?;
          if (_currentDeviceStatus != null &&
              (volume != null || muted != null)) {
            _updateStatus(
              _currentDeviceStatus!.copyWith(
                volume: volume ?? _currentDeviceStatus!.volume,
                muted: muted ?? _currentDeviceStatus!.muted,
              ),
            );
          }
          return;
        default:
          return;
      }
    });
  }

  void _scheduleAndroidRouteRefresh() {
    _androidRouteRefreshDebounceTimer?.cancel();
    _androidRouteRefreshDebounceTimer = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(
        _refreshAndroidRouteStatus(
          formatOverride: _lastKnownFormat,
          isPlaying: _lastKnownIsPlaying,
          hasActiveSong: _lastKnownHasSong,
        ),
      ),
    );
  }

  Future<List<Uac2DeviceInfo>> listDevices() async {
    if (Platform.isAndroid) {
      final currentPlaybackDevice = _currentAndroidPlaybackDeviceIfReusable(
        requireActivatableDeviceName: false,
      );
      if (currentPlaybackDevice != null) {
        debugPrint(
          'Uac2Service.listDevices (Android): reusing frozen direct USB device '
          '${_describeAndroidDevice(currentPlaybackDevice)}',
        );
        return [currentPlaybackDevice];
      }
      return _listDevicesAndroid();
    }
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
      if (raw == null) {
        debugPrint(
          'Uac2Service.listDevices (Android): no UsbManager devices returned',
        );
        return [];
      }
      final devices = raw.map((e) {
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
      debugPrint(
        'Uac2Service.listDevices (Android): ${devices.length} candidate(s): '
        '${devices.map((device) => '${device.productName}@${device.deviceName}').join(', ')}',
      );
      return devices;
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
    if (Platform.isAndroid) {
      final debugState = await getAndroidPlaybackDebugState();
      final rustAudioState = debugState?['rustAudioState'];
      final directUsbState = rustAudioState is Map
          ? (rustAudioState['direct_usb'] ?? rustAudioState['directUsb'])
          : null;
      if (directUsbState is! Map) {
        return null;
      }

      List<int> intList(dynamic value) {
        if (value is List) {
          return value.whereType<num>().map((entry) => entry.toInt()).toList();
        }
        return const [];
      }

      return Uac2DeviceCapabilities(
        supportedSampleRates: intList(
          directUsbState['supported_sample_rates'] ??
              directUsbState['supportedSampleRates'],
        ),
        supportedBitDepths: intList(
          directUsbState['supported_bit_depths'] ??
              directUsbState['supportedBitDepths'],
        ),
        supportedChannels: intList(
          directUsbState['supported_channels'] ??
              directUsbState['supportedChannels'],
        ),
        deviceType: 'Direct USB DAC',
      );
    }
    if (!rust_uac2.uac2IsAvailable()) return null;
    try {
      return const Uac2DeviceCapabilities(
        supportedSampleRates: [
          44100,
          48000,
          88200,
          96000,
          176400,
          192000,
          352800,
          384000,
        ],
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
      final resolvedDevice = Platform.isAndroid
          ? await _resolveConnectedAndroidDevice(device)
          : device;

      _updateStatus(
        Uac2DeviceStatus(
          device: resolvedDevice ?? device,
          state: Uac2State.connecting,
        ),
      );

      if (Platform.isAndroid) {
        final androidDevice = resolvedDevice;
        final deviceIdentifier = androidDevice?.deviceName;
        if (androidDevice == null ||
            deviceIdentifier == null ||
            deviceIdentifier.isEmpty) {
          _updateStatus(
            Uac2DeviceStatus(
              device: _sanitizeAndroidDeviceForLookup(device),
              state: Uac2State.error,
              errorMessage: 'USB device not found',
            ),
          );
          return false;
        }

        final hasPermission = await this.hasPermission(deviceIdentifier);
        if (!hasPermission) {
          final granted = await requestPermission(deviceIdentifier);
          if (!granted) {
            _updateStatus(
              Uac2DeviceStatus(
                device: androidDevice,
                state: Uac2State.error,
                errorMessage: 'Permission denied',
              ),
            );
            return false;
          }
        }

        final activated = await _channel.invokeMethod<bool>(
          'activateDirectUsb',
          {'deviceName': deviceIdentifier},
        );
        if (activated != true) {
          _updateStatus(
            Uac2DeviceStatus(
              device: androidDevice,
              state: Uac2State.error,
              errorMessage: 'Failed to activate direct USB DAC',
            ),
          );
          return false;
        }

        final bitPerfectEnabled = await _preferencesService
            .getBitPerfectEnabled();
        await _channel.invokeMethod<bool>('setExclusiveDacMode', {
          'enabled': bitPerfectEnabled,
        });

        await _preferencesService.saveSelectedDevice(androidDevice);
        await _refreshAndroidRouteStatus(
          preferredDevice: androidDevice,
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

  Future<bool> prepareAndroidExperimentalUsbPlayback({
    required Uac2AudioFormat format,
    Set<int> disallowedSampleRates = const <int>{},
  }) async {
    if (!Platform.isAndroid) {
      return false;
    }

    await initialize();
    final resolvedDevice = await _resolvePreferredAndroidActivationDevice(null);
    if (resolvedDevice == null ||
        !(resolvedDevice.deviceName?.isNotEmpty ?? false)) {
      debugPrint(
        'Uac2Service.prepareAndroidExperimentalUsbPlayback: no activatable '
        'USB DAC was resolved',
      );
      return false;
    }

    final selected = await selectDevice(resolvedDevice);
    if (!selected) {
      return false;
    }

    final capabilities = await getDeviceCapabilities(resolvedDevice);
    final selectedFormat = _chooseAndroidExperimentalUsbOutputFormat(
      format,
      capabilities,
      disallowedSampleRates: disallowedSampleRates,
    );
    if (selectedFormat == null) {
      debugPrint(
        'Uac2Service.prepareAndroidExperimentalUsbPlayback: no compatible '
        'direct USB output format could be selected for requested '
        '${format.sampleRate}Hz/${format.bitDepth}-bit/${format.channels}ch',
      );
      return false;
    }
    final usingFallbackFormat =
        selectedFormat.sampleRate != format.sampleRate ||
        selectedFormat.bitDepth != format.bitDepth ||
        selectedFormat.channels != format.channels;
    if (usingFallbackFormat) {
      debugPrint(
        'Uac2Service.prepareAndroidExperimentalUsbPlayback: using fallback '
        'direct USB output ${selectedFormat.sampleRate}Hz/'
        '${selectedFormat.bitDepth}-bit/${selectedFormat.channels}ch for '
        'requested ${format.sampleRate}Hz/${format.bitDepth}-bit/'
        '${format.channels}ch',
      );
    }
    if (capabilities != null) {
      final sampleRateSupported =
          capabilities.supportedSampleRates.isEmpty ||
          capabilities.supportedSampleRates.contains(selectedFormat.sampleRate);
      final bitDepthSupported =
          capabilities.supportedBitDepths.isEmpty ||
          capabilities.supportedBitDepths.contains(selectedFormat.bitDepth);
      final channelCountSupported =
          capabilities.supportedChannels.isEmpty ||
          capabilities.supportedChannels.contains(selectedFormat.channels);
      if (!sampleRateSupported ||
          !bitDepthSupported ||
          !channelCountSupported) {
        debugPrint(
          'Uac2Service.prepareAndroidExperimentalUsbPlayback: requested '
          '${selectedFormat.sampleRate}Hz/${selectedFormat.bitDepth}-bit/'
          '${selectedFormat.channels}ch '
          'is not advertised by the selected DAC capabilities',
        );
        return false;
      }
    }

    try {
      final applied = await _channel
          .invokeMethod<bool>('setDirectUsbPlaybackFormat', {
            'sampleRate': selectedFormat.sampleRate,
            'bitDepth': selectedFormat.bitDepth,
            'channels': selectedFormat.channels,
          });
      if (applied != true) {
        debugPrint(
          'Uac2Service.setDirectUsbPlaybackFormat returned false for '
          '${selectedFormat.sampleRate}Hz/${selectedFormat.bitDepth}-bit/'
          '${selectedFormat.channels}ch',
        );
        return false;
      }
    } catch (e) {
      debugPrint('Uac2Service.setDirectUsbPlaybackFormat failed: $e');
      return false;
    }

    await _refreshAndroidRouteStatus(
      preferredDevice: resolvedDevice,
      formatOverride: selectedFormat,
      isPlaying: false,
      hasActiveSong: true,
    );
    return true;
  }

  Future<Uac2AudioFormat?> suggestAndroidExperimentalUsbOutputFormat({
    required Uac2AudioFormat requested,
    Set<int> disallowedSampleRates = const <int>{},
  }) async {
    if (!Platform.isAndroid) {
      return requested;
    }

    final device =
        currentDeviceStatus?.device ??
        await _resolvePreferredAndroidActivationDevice(null);
    final capabilities = device == null
        ? null
        : await getDeviceCapabilities(device);
    return _chooseAndroidExperimentalUsbOutputFormat(
      requested,
      capabilities,
      disallowedSampleRates: disallowedSampleRates,
    );
  }

  Uac2AudioFormat? _chooseAndroidExperimentalUsbOutputFormat(
    Uac2AudioFormat requested,
    Uac2DeviceCapabilities? capabilities, {
    Set<int> disallowedSampleRates = const <int>{},
  }) {
    final supportedSampleRates =
        (capabilities?.supportedSampleRates ?? const <int>[])
            .where((rate) => !disallowedSampleRates.contains(rate))
            .toSet()
            .toList()
          ..sort();
    final supportedBitDepths =
        (capabilities?.supportedBitDepths ?? const <int>[]).toSet().toList()
          ..sort();
    final supportedChannels =
        (capabilities?.supportedChannels ?? const <int>[]).toSet().toList()
          ..sort();

    final sampleRate = switch (supportedSampleRates.isEmpty) {
      true when disallowedSampleRates.contains(requested.sampleRate) =>
        _preferredAndroidUsbFallbackRates(
          requested.sampleRate,
        ).cast<int?>().firstWhere(
          (rate) => rate != null && !disallowedSampleRates.contains(rate),
          orElse: () => null,
        ),
      true => requested.sampleRate,
      false when supportedSampleRates.contains(requested.sampleRate) =>
        requested.sampleRate,
      false =>
        _preferredAndroidUsbFallbackRates(requested.sampleRate).firstWhere(
          supportedSampleRates.contains,
          orElse: () => supportedSampleRates.first,
        ),
    };

    if (sampleRate == null) {
      return null;
    }

    final bitDepth = supportedBitDepths.isEmpty
        ? requested.bitDepth
        : supportedBitDepths.contains(requested.bitDepth)
        ? requested.bitDepth
        : supportedBitDepths.last;
    final channels = supportedChannels.isEmpty
        ? requested.channels
        : supportedChannels.contains(requested.channels)
        ? requested.channels
        : supportedChannels.contains(2)
        ? 2
        : supportedChannels.first;

    return Uac2AudioFormat(
      sampleRate: sampleRate,
      bitDepth: bitDepth,
      channels: channels,
    );
  }

  List<int> _preferredAndroidUsbFallbackRates(int requestedSampleRate) {
    final preferred = <int>[
      48000,
      96000,
      192000,
      384000,
      44100,
      88200,
      176400,
      352800,
      requestedSampleRate,
    ];
    final deduped = <int>{};
    for (final rate in preferred) {
      deduped.add(rate);
    }
    return deduped.toList();
  }

  Future<bool> resetAndroidDirectUsbPath({Uac2AudioFormat? format}) async {
    if (!Platform.isAndroid) {
      return false;
    }

    final resolvedDevice = await _resolvePreferredAndroidActivationDevice(null);
    if (resolvedDevice == null ||
        !(resolvedDevice.deviceName?.isNotEmpty ?? false)) {
      return false;
    }

    await releaseAndroidDirectUsbRuntime();
    final selected = await selectDevice(resolvedDevice);
    if (!selected) {
      return false;
    }

    if (format != null) {
      try {
        final applied = await _channel
            .invokeMethod<bool>('setDirectUsbPlaybackFormat', {
              'sampleRate': format.sampleRate,
              'bitDepth': format.bitDepth,
              'channels': format.channels,
            });
        if (applied != true) {
          debugPrint(
            'Uac2Service.resetAndroidDirectUsbPath format apply returned '
            'false for ${format.sampleRate}Hz/${format.bitDepth}-bit/'
            '${format.channels}ch',
          );
          return false;
        }
      } catch (e) {
        debugPrint(
          'Uac2Service.resetAndroidDirectUsbPath format apply failed: $e',
        );
        return false;
      }
    }

    await _refreshAndroidRouteStatus(
      preferredDevice: resolvedDevice,
      formatOverride: format ?? _lastKnownFormat,
      isPlaying: false,
      hasActiveSong: _lastKnownHasSong,
    );
    return true;
  }

  Future<void> releaseAndroidDirectUsbRuntime() async {
    if (!Platform.isAndroid) {
      return;
    }

    final preferredDevice = await _resolvePreferredAndroidDevice(null);
    await _setAndroidDirectUsbPlaybackActive(false);
    try {
      await _channel.invokeMethod<bool>('clearDirectUsbPlaybackFormat');
    } catch (e) {
      debugPrint('Uac2Service.clearDirectUsbPlaybackFormat failed: $e');
    }
    try {
      await _channel.invokeMethod<bool>('deactivateDirectUsb');
    } catch (e) {
      debugPrint('Uac2Service.deactivateDirectUsb failed: $e');
    }

    await _refreshAndroidRouteStatus(
      preferredDevice: preferredDevice,
      formatOverride: _lastKnownFormat,
      isPlaying: false,
      hasActiveSong: _lastKnownHasSong,
    );
  }

  Future<void> markAndroidDirectUsbFallback(String reason) async {
    if (!Platform.isAndroid) {
      return;
    }

    try {
      await _channel.invokeMethod<bool>('markDirectUsbFallback', {
        'reason': reason,
      });
    } catch (e) {
      debugPrint('Uac2Service.markDirectUsbFallback failed: $e');
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
        await _setAndroidDirectUsbPlaybackActive(false);
        try {
          await _channel.invokeMethod<bool>('deactivateDirectUsb');
        } catch (e) {
          debugPrint('Uac2Service.deactivateDirectUsb failed: $e');
        }
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
    if (Platform.isAndroid &&
        _currentDeviceStatus!.hasVolumeControl &&
        !_currentDeviceStatus!.volumeControlWritable) {
      return false;
    }

    try {
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod<bool>('setRouteVolume', {
          'volume': volume,
        });
        if (result == true) {
          _updateStatus(_currentDeviceStatus!.copyWith(volume: volume));
        }
        return result ?? false;
      }
      if (!rust_uac2.uac2IsAvailable()) return false;
      await rust_uac2.uac2SetVolume(volume: volume);
      _updateStatus(_currentDeviceStatus!.copyWith(volume: volume));
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
    if (Platform.isAndroid &&
        _currentDeviceStatus!.hasVolumeControl &&
        !_currentDeviceStatus!.volumeControlWritable) {
      return false;
    }

    try {
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod<bool>('setRouteMuted', {
          'muted': muted,
        });
        if (result == true) {
          _updateStatus(_currentDeviceStatus!.copyWith(muted: muted));
        }
        return result ?? false;
      }
      if (!rust_uac2.uac2IsAvailable()) return false;
      await rust_uac2.uac2SetMute(muted: muted);
      _updateStatus(_currentDeviceStatus!.copyWith(muted: muted));
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
    AudioEngineType? playbackMode,
  }) async {
    final syncGeneration = ++_playbackStatusSyncGeneration;
    final hasActiveSong = song != null;
    _lastKnownFormat = formatOverride;
    _lastKnownIsPlaying = isPlaying;
    _lastKnownHasSong = hasActiveSong;

    if (Platform.isAndroid) {
      final usingExperimentalUsb =
          playbackMode == AudioEngineType.usbDacExperimental;
      final shouldMarkDirectPlaybackActive =
          _shouldKeepAndroidDirectUsbPlaybackActive(
            usingExperimentalUsb: usingExperimentalUsb,
            isPlaying: isPlaying,
            hasActiveSong: hasActiveSong,
          );
      Uac2DeviceInfo? resolvedPreferredDevice;
      if (usingExperimentalUsb) {
        resolvedPreferredDevice =
            _currentAndroidPlaybackDeviceIfReusable(
              requireActivatableDeviceName: true,
            ) ??
            await _resolvePreferredAndroidActivationDevice(null);
        if (!_isCurrentPlaybackStatusSync(syncGeneration)) {
          return;
        }
        if (resolvedPreferredDevice != null &&
            (resolvedPreferredDevice.deviceName?.isNotEmpty ?? false) &&
            _shouldActivateAndroidDirectUsb(resolvedPreferredDevice)) {
          await selectDevice(resolvedPreferredDevice);
          if (!_isCurrentPlaybackStatusSync(syncGeneration)) {
            return;
          }
        }
      } else {
        resolvedPreferredDevice = await _resolvePreferredAndroidDevice(null);
        if (!_isCurrentPlaybackStatusSync(syncGeneration)) {
          return;
        }
      }

      // Caller should pass isPlaying=true while Rust holds the live USB stream
      // (including buffering), and a non-null [song] whenever a track is loaded
      // so we do not abandon direct USB audio focus mid-stream.
      await _setAndroidDirectUsbPlaybackActive(shouldMarkDirectPlaybackActive);
      if (!_isCurrentPlaybackStatusSync(syncGeneration)) {
        return;
      }

      if (_canReuseActiveAndroidDirectPlaybackStatus(
        preferredDevice: resolvedPreferredDevice,
        directPlaybackActive: shouldMarkDirectPlaybackActive,
        hasActiveSong: hasActiveSong,
      )) {
        _updateStatus(
          _currentDeviceStatus!.copyWith(
            device: resolvedPreferredDevice ?? _currentDeviceStatus!.device,
            state: isPlaying
                ? Uac2State.streaming
                : _currentDeviceStatus!.state,
            errorMessage: null,
            currentFormat: formatOverride ?? _lastKnownFormat,
          ),
        );
        return;
      }

      await _refreshAndroidRouteStatus(
        preferredDevice: resolvedPreferredDevice,
        formatOverride: formatOverride,
        isPlaying: isPlaying,
        hasActiveSong: hasActiveSong,
        syncGeneration: syncGeneration,
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
    int? syncGeneration,
  }) async {
    final resolvedPreferredDevice = await _resolvePreferredAndroidDevice(
      preferredDevice,
    );
    if (syncGeneration != null &&
        !_isCurrentPlaybackStatusSync(syncGeneration)) {
      return;
    }
    final routeStatus = await _getAndroidRouteStatus(
      preferredDevice: resolvedPreferredDevice,
    );
    if (syncGeneration != null &&
        !_isCurrentPlaybackStatusSync(syncGeneration)) {
      return;
    }
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
          warningMessage: null,
          currentFormat: effectiveFormat,
        ),
      );
      return;
    }

    final routeType = _routeTypeFromString(routeStatus['routeType'] as String?);
    final routeLabel = routeStatus['routeLabel'] as String?;
    final isExternal = routeStatus['isExternal'] == true;
    final preferredUsbDetected =
        routeStatus['preferredUsbDeviceDetected'] == true;
    final directUsbRegistered = routeStatus['directUsbRegistered'] == true;
    final volumeMode = _volumeModeFromString(
      routeStatus['volumeMode'] as String?,
    );
    final hasVolumeControl = routeStatus['hasVolumeControl'] == true;
    final volumeControlWritable =
        hasVolumeControl && routeStatus['volumeControlWritable'] != false;
    final volume = (routeStatus['volume'] as num?)?.toDouble();
    final muted = routeStatus['muted'] as bool?;

    if (!effectiveHasSong &&
        !effectiveIsPlaying &&
        !isExternal &&
        !prefersExternalDevice &&
        !preferredUsbDetected &&
        !directUsbRegistered) {
      _updateStatus(null);
      return;
    }

    if (!effectiveHasSong &&
        !effectiveIsPlaying &&
        prefersExternalDevice &&
        routeType != Uac2RouteType.externalUsb &&
        !preferredUsbDetected &&
        !directUsbRegistered) {
      _updateStatus(
        Uac2DeviceStatus(
          device: resolvedPreferredDevice,
          state: Uac2State.error,
          errorMessage: 'Selected USB DAC not detected',
          warningMessage: null,
          currentFormat: effectiveFormat,
          routeType: routeType,
          routeLabel: routeLabel,
          isExternalRoute: false,
          volumeMode: volumeMode,
          hasVolumeControl: hasVolumeControl,
          volumeControlWritable: volumeControlWritable,
          volume: volume,
          muted: muted,
        ),
      );
      return;
    }

    final usbDeviceAvailable =
        routeType == Uac2RouteType.externalUsb ||
        preferredUsbDetected ||
        directUsbRegistered;
    final routeDevice = _deviceFromAndroidRoute(
      routeStatus,
      preferredDevice: usbDeviceAvailable ? resolvedPreferredDevice : null,
    );

    final isStreamingState = _isAndroidStreamingRoute(
      routeType,
      preferredUsbDetected: preferredUsbDetected,
      directUsbRegistered: directUsbRegistered,
    );

    _updateStatus(
      Uac2DeviceStatus(
        device: routeDevice,
        state: effectiveIsPlaying && isStreamingState
            ? Uac2State.streaming
            : Uac2State.connected,
        errorMessage: null,
        warningMessage: _androidRouteWarningMessage(
          routeType,
          preferredUsbDetected: preferredUsbDetected,
          directUsbRegistered: directUsbRegistered,
        ),
        currentFormat: effectiveFormat,
        routeType: routeType,
        routeLabel: routeLabel,
        isExternalRoute:
            isExternal || preferredUsbDetected || directUsbRegistered,
        volumeMode: volumeMode,
        hasVolumeControl: hasVolumeControl,
        volumeControlWritable: volumeControlWritable,
        volume: volume,
        muted: muted,
      ),
    );
  }

  Future<rust_audio.AudioCapabilityInfo> getAndroidAudioCapabilityInfo() async {
    if (!Platform.isAndroid) {
      return const rust_audio.AudioCapabilityInfo(
        capabilities: [rust_audio.AudioCapabilityType.standard],
        routeType: 'unknown',
        routeLabel: null,
        maxSampleRate: null,
      );
    }

    final frozenCapabilityInfo = _frozenAndroidAudioCapabilityInfo();
    if (frozenCapabilityInfo != null) {
      return frozenCapabilityInfo;
    }

    final resolvedPreferredDevice = await _resolvePreferredAndroidDevice(null);
    try {
      final raw = await _channel
          .invokeMapMethod<dynamic, dynamic>('getAudioCapabilities', {
            'deviceName': resolvedPreferredDevice?.deviceName,
            'productName': resolvedPreferredDevice?.productName,
            'vendorId': resolvedPreferredDevice?.vendorId,
            'productId': resolvedPreferredDevice?.productId,
            'serial': resolvedPreferredDevice?.serial,
          });

      if (raw == null) {
        return const rust_audio.AudioCapabilityInfo(
          capabilities: [rust_audio.AudioCapabilityType.standard],
          routeType: 'unknown',
          routeLabel: null,
          maxSampleRate: null,
        );
      }

      final map = raw.map((key, value) => MapEntry(key.toString(), value));
      final rawCapabilities =
          (map['capabilities'] as List<dynamic>? ?? const <dynamic>[])
              .whereType<String>()
              .toList();
      final capabilities = rawCapabilities.isEmpty
          ? const [rust_audio.AudioCapabilityType.standard]
          : rawCapabilities
                .map(_audioCapabilityTypeFromString)
                .toSet()
                .toList();

      return rust_audio.AudioCapabilityInfo(
        capabilities: capabilities,
        routeType: map['routeType'] as String? ?? 'unknown',
        routeLabel: map['routeLabel'] as String?,
        maxSampleRate: (map['maxSupportedSampleRate'] as num?)?.toInt(),
      );
    } catch (e) {
      debugPrint('Uac2Service.getAndroidAudioCapabilityInfo failed: $e');
      return const rust_audio.AudioCapabilityInfo(
        capabilities: [rust_audio.AudioCapabilityType.standard],
        routeType: 'unknown',
        routeLabel: null,
        maxSampleRate: null,
      );
    }
  }

  rust_audio.AudioCapabilityInfo? _frozenAndroidAudioCapabilityInfo() {
    if (!_hasFrozenAndroidDirectUsbSession()) {
      return null;
    }

    final currentStatus = _currentDeviceStatus!;

    return rust_audio.AudioCapabilityInfo(
      capabilities: const [rust_audio.AudioCapabilityType.usbDac],
      routeType: 'usb',
      routeLabel: currentStatus.routeLabel ?? currentStatus.device.productName,
      maxSampleRate:
          currentStatus.currentFormat?.sampleRate ??
          _lastKnownFormat?.sampleRate,
    );
  }

  Future<Map<String, dynamic>?> getAndroidPlaybackDebugState() async {
    if (!Platform.isAndroid) {
      return null;
    }

    try {
      final raw = await _channel.invokeMapMethod<dynamic, dynamic>(
        'getDirectUsbDiagnostics',
      );
      if (raw == null) {
        return null;
      }

      final map = raw.map((key, value) => MapEntry(key.toString(), value));
      final rustJson = map['rustAudioStateJson'] as String?;
      if (rustJson != null && rustJson.isNotEmpty) {
        try {
          final parsed = jsonDecode(rustJson);
          if (parsed is Map<String, dynamic>) {
            map['rustAudioState'] = parsed;
          } else if (parsed is Map) {
            map['rustAudioState'] = parsed.map(
              (key, value) => MapEntry(key.toString(), value),
            );
          }
        } catch (e) {
          debugPrint(
            'Uac2Service.getAndroidPlaybackDebugState JSON failed: $e',
          );
        }
      }
      return map;
    } catch (e) {
      debugPrint('Uac2Service.getAndroidPlaybackDebugState failed: $e');
      return null;
    }
  }

  Future<Uac2DeviceInfo?> _resolvePreferredAndroidDevice(
    Uac2DeviceInfo? preferredDevice,
  ) async {
    return _resolvePreferredAndroidDeviceInternal(
      preferredDevice,
      requireActivatableDeviceName: false,
    );
  }

  Future<Uac2DeviceInfo?> _resolvePreferredAndroidActivationDevice(
    Uac2DeviceInfo? preferredDevice,
  ) async {
    return _resolvePreferredAndroidDeviceInternal(
      preferredDevice,
      requireActivatableDeviceName: true,
    );
  }

  Future<Uac2DeviceInfo?> _resolvePreferredAndroidDeviceInternal(
    Uac2DeviceInfo? preferredDevice, {
    required bool requireActivatableDeviceName,
  }) async {
    final currentPlaybackDevice = _currentAndroidPlaybackDeviceIfReusable(
      requireActivatableDeviceName: requireActivatableDeviceName,
    );
    if (currentPlaybackDevice != null &&
        (preferredDevice == null ||
            _isSameAndroidDevice(currentPlaybackDevice, preferredDevice))) {
      return currentPlaybackDevice;
    }

    final preferredRouteLabelHint =
        _currentDeviceStatus?.routeLabel ?? preferredDevice?.productName;

    if (_hasUsbLookupIdentity(preferredDevice)) {
      final resolvedPreferred = await _resolveConnectedAndroidDevice(
        preferredDevice,
      );
      if (_isUsableResolvedAndroidDevice(
        resolvedPreferred,
        requireActivatableDeviceName: requireActivatableDeviceName,
      )) {
        debugPrint(
          'Uac2Service._resolvePreferredAndroidDevice: using explicit '
          'preferred device ${_describeAndroidDevice(resolvedPreferred)}',
        );
        return resolvedPreferred;
      }
    }

    final currentDevice = _currentDeviceStatus;
    if (currentDevice != null && currentDevice.isExternalRoute) {
      final resolvedCurrentDevice = await _resolveConnectedAndroidDevice(
        currentDevice.device,
      );
      if (_isUsableResolvedAndroidDevice(
        resolvedCurrentDevice,
        requireActivatableDeviceName: requireActivatableDeviceName,
      )) {
        debugPrint(
          'Uac2Service._resolvePreferredAndroidDevice: using current route '
          'device ${_describeAndroidDevice(resolvedCurrentDevice)}',
        );
        return resolvedCurrentDevice;
      }
    }

    final storedDevice = await _preferencesService.loadSelectedDevice();
    final resolvedStoredDevice = await _resolveConnectedAndroidDevice(
      storedDevice,
    );
    if (_isUsableResolvedAndroidDevice(
      resolvedStoredDevice,
      requireActivatableDeviceName: requireActivatableDeviceName,
    )) {
      debugPrint(
        'Uac2Service._resolvePreferredAndroidDevice: using stored device '
        '${_describeAndroidDevice(resolvedStoredDevice)}',
      );
      return resolvedStoredDevice;
    }

    final discoveredDevice = await _discoverDefaultAndroidUsbDevice(
      routeLabelHint: preferredRouteLabelHint,
    );
    if (_isUsableResolvedAndroidDevice(
      discoveredDevice,
      requireActivatableDeviceName: requireActivatableDeviceName,
    )) {
      debugPrint(
        'Uac2Service._resolvePreferredAndroidDevice: discovered default '
        'device ${_describeAndroidDevice(discoveredDevice)}',
      );
      return discoveredDevice;
    }

    debugPrint(
      'Uac2Service._resolvePreferredAndroidDevice: no usable Android USB '
      'device resolved (requireDeviceName=$requireActivatableDeviceName)',
    );
    return null;
  }

  Future<Uac2DeviceInfo?> _resolveConnectedAndroidDevice(
    Uac2DeviceInfo? preferredDevice,
  ) async {
    if (!Platform.isAndroid || preferredDevice == null) {
      return preferredDevice;
    }

    final currentPlaybackDevice = _currentAndroidPlaybackDeviceIfReusable(
      requireActivatableDeviceName: false,
    );
    if (currentPlaybackDevice != null &&
        (_isSameAndroidDevice(currentPlaybackDevice, preferredDevice) ||
            currentPlaybackDevice.deviceName == preferredDevice.deviceName ||
            _matchesAndroidIdentifierAlias(
              preferredDevice.serial,
              currentPlaybackDevice.deviceName,
            ) ||
            preferredDevice.serial == currentPlaybackDevice.serial)) {
      return currentPlaybackDevice;
    }

    final devices = await _listDevicesAndroid();

    final preferredDeviceName = preferredDevice.deviceName;
    if (preferredDeviceName?.isNotEmpty ?? false) {
      for (final device in devices) {
        if (device.deviceName == preferredDeviceName) {
          return device;
        }
      }
    }

    final preferredSerial = preferredDevice.serial;
    if (preferredSerial?.isNotEmpty ?? false) {
      for (final device in devices) {
        if (_matchesAndroidIdentifierAlias(
              preferredSerial,
              device.deviceName,
            ) ||
            preferredSerial == device.serial) {
          return device;
        }
      }
    }

    for (final device in devices) {
      if (_isSameAndroidDevice(device, preferredDevice)) {
        return device;
      }
    }

    if (!_hasUsbLookupIdentity(preferredDevice)) {
      return null;
    }

    return _sanitizeAndroidDeviceForLookup(preferredDevice);
  }

  bool _hasUsbLookupIdentity(Uac2DeviceInfo? device) {
    if (device == null) {
      return false;
    }

    return (device.deviceName?.isNotEmpty ?? false) ||
        device.vendorId != 0 ||
        device.productId != 0 ||
        (device.serial?.isNotEmpty ?? false);
  }

  bool _isUsableResolvedAndroidDevice(
    Uac2DeviceInfo? device, {
    required bool requireActivatableDeviceName,
  }) {
    if (device == null) {
      return false;
    }

    if (requireActivatableDeviceName) {
      return device.deviceName?.isNotEmpty ?? false;
    }

    return _hasUsbLookupIdentity(device) ||
        (device.productName.isNotEmpty && device.manufacturer.isNotEmpty);
  }

  String _describeAndroidDevice(Uac2DeviceInfo? device) {
    if (device == null) {
      return 'none';
    }

    return '${device.productName} '
        '[vid=${device.vendorId}, pid=${device.productId}, '
        'serial=${device.serial ?? 'none'}, '
        'deviceName=${device.deviceName ?? 'none'}]';
  }

  Uac2DeviceInfo _sanitizeAndroidDeviceForLookup(Uac2DeviceInfo device) {
    return Uac2DeviceInfo(
      vendorId: device.vendorId,
      productId: device.productId,
      serial: device.serial,
      productName: device.productName,
      manufacturer: device.manufacturer,
      deviceName: null,
    );
  }

  Future<Uac2DeviceInfo?> _discoverDefaultAndroidUsbDevice({
    String? routeLabelHint,
  }) async {
    if (!Platform.isAndroid) {
      return null;
    }

    final devices = await _listDevicesAndroid();
    if (devices.isEmpty) {
      debugPrint(
        'Uac2Service._discoverDefaultAndroidUsbDevice: no UsbManager audio devices found',
      );
      return null;
    }

    if (routeLabelHint != null && routeLabelHint.isNotEmpty) {
      final normalizedRouteLabel = routeLabelHint.toLowerCase();
      for (final device in devices) {
        final productName = device.productName.toLowerCase();
        final manufacturer = device.manufacturer.toLowerCase();
        if (normalizedRouteLabel.contains(productName) ||
            (manufacturer.isNotEmpty &&
                normalizedRouteLabel.contains(manufacturer))) {
          debugPrint(
            'Uac2Service._discoverDefaultAndroidUsbDevice matched route '
            'label "$routeLabelHint" to ${device.productName}',
          );
          return device;
        }
      }
    }

    debugPrint(
      'Uac2Service._discoverDefaultAndroidUsbDevice falling back to first '
      'UsbManager DAC candidate: ${devices.first.productName}',
    );
    return devices.first;
  }

  bool _shouldActivateAndroidDirectUsb(Uac2DeviceInfo preferredDevice) {
    final currentStatus = _currentDeviceStatus;
    if (currentStatus == null) {
      return true;
    }

    if (!_isSameAndroidDevice(currentStatus.device, preferredDevice)) {
      return true;
    }

    // Retry activation only after an explicit error. Do not use
    // !isExternalRoute: Android route labels flicker (e.g. internal codename vs
    // "USB-Audio - …") while the DAC is stable; syncPlaybackStatus would then
    // call selectDevice/activateDirectUsb again during libusb streaming and can
    // trigger libusb_handle_events I/O failures.
    return currentStatus.state == Uac2State.error;
  }

  Uac2DeviceInfo? _currentAndroidPlaybackDeviceIfReusable({
    required bool requireActivatableDeviceName,
  }) {
    final currentStatus = _currentDeviceStatus;
    if (currentStatus == null ||
        currentStatus.state == Uac2State.error ||
        !_hasFrozenAndroidDirectUsbSession()) {
      return null;
    }

    final device = currentStatus.device;
    if (requireActivatableDeviceName &&
        !(device.deviceName?.isNotEmpty ?? false)) {
      return null;
    }
    return device;
  }

  bool _canReuseActiveAndroidDirectPlaybackStatus({
    required Uac2DeviceInfo? preferredDevice,
    required bool directPlaybackActive,
    required bool hasActiveSong,
  }) {
    if (!directPlaybackActive || !hasActiveSong) {
      return false;
    }

    final currentStatus = _currentDeviceStatus;
    if (currentStatus == null ||
        currentStatus.state == Uac2State.error ||
        currentStatus.routeType != Uac2RouteType.externalUsb) {
      return false;
    }

    if (preferredDevice == null) {
      return true;
    }
    return _isSameAndroidDevice(currentStatus.device, preferredDevice);
  }

  bool _shouldKeepAndroidDirectUsbPlaybackActive({
    required bool usingExperimentalUsb,
    required bool isPlaying,
    required bool hasActiveSong,
  }) {
    if (!usingExperimentalUsb || !hasActiveSong) {
      return false;
    }
    if (isPlaying) {
      return true;
    }

    return _hasFrozenAndroidDirectUsbSession();
  }

  bool _hasFrozenAndroidDirectUsbSession() {
    if (!Platform.isAndroid) {
      return false;
    }

    final currentStatus = _currentDeviceStatus;
    if (currentStatus == null || currentStatus.state == Uac2State.error) {
      return false;
    }

    final looksLikeActiveUsbRoute =
        currentStatus.routeType == Uac2RouteType.externalUsb ||
        (currentStatus.isExternalRoute &&
            _hasUsbLookupIdentity(currentStatus.device));
    if (!looksLikeActiveUsbRoute) {
      return false;
    }

    return _lastDirectUsbPlaybackActive == true ||
        currentStatus.state == Uac2State.streaming;
  }

  bool _isCurrentPlaybackStatusSync(int generation) {
    return generation == _playbackStatusSyncGeneration;
  }

  Future<void> _setAndroidDirectUsbPlaybackActive(bool active) async {
    if (_lastDirectUsbPlaybackActive == active) {
      return;
    }

    try {
      await _channel.invokeMethod<bool>('setDirectUsbPlaybackActive', {
        'active': active,
      });
      _lastDirectUsbPlaybackActive = active;
    } catch (e) {
      debugPrint('Uac2Service.setDirectUsbPlaybackActive failed: $e');
    }
  }

  bool _isSameAndroidDevice(Uac2DeviceInfo a, Uac2DeviceInfo b) {
    final hasDeviceName =
        (a.deviceName?.isNotEmpty ?? false) &&
        (b.deviceName?.isNotEmpty ?? false);
    if (hasDeviceName) {
      return a.deviceName == b.deviceName;
    }

    if (_matchesAndroidIdentifierAlias(a.serial, b.deviceName) ||
        _matchesAndroidIdentifierAlias(b.serial, a.deviceName)) {
      return true;
    }

    final sameVendorProduct =
        a.vendorId == b.vendorId && a.productId == b.productId;
    if (!sameVendorProduct) {
      return false;
    }

    final serialA = a.serial;
    final serialB = b.serial;
    final hasSerial =
        (serialA?.isNotEmpty ?? false) && (serialB?.isNotEmpty ?? false);
    if (hasSerial) {
      if (serialA == serialB) {
        return true;
      }

      final serialALooksLikeDeviceName = _looksLikeAndroidUsbDeviceName(
        serialA,
      );
      final serialBLooksLikeDeviceName = _looksLikeAndroidUsbDeviceName(
        serialB,
      );
      if (!serialALooksLikeDeviceName && !serialBLooksLikeDeviceName) {
        return false;
      }
      if (serialALooksLikeDeviceName && serialBLooksLikeDeviceName) {
        return false;
      }
    }

    final sameProductName = a.productName == b.productName;
    final sameManufacturer =
        a.manufacturer.isNotEmpty &&
        b.manufacturer.isNotEmpty &&
        a.manufacturer == b.manufacturer;
    return sameProductName &&
        (sameManufacturer || a.manufacturer.isEmpty || b.manufacturer.isEmpty);
  }

  bool _matchesAndroidIdentifierAlias(String? first, String? second) {
    return (first?.isNotEmpty ?? false) &&
        (second?.isNotEmpty ?? false) &&
        first == second;
  }

  bool _looksLikeAndroidUsbDeviceName(String? value) {
    if (value == null || value.isEmpty) {
      return false;
    }
    return value.startsWith('/dev/bus/usb/');
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

  Future<bool> setBitPerfectEnabled(bool enabled, {bool persist = true}) async {
    if (persist) {
      await _preferencesService.setBitPerfectEnabled(enabled);
    }
    bitPerfectEnabledNotifier.value = enabled;

    if (!Platform.isAndroid) {
      return false;
    }

    if (enabled) {
      final preferredDevice = await _resolvePreferredAndroidActivationDevice(
        null,
      );
      if (preferredDevice != null &&
          (preferredDevice.deviceName?.isNotEmpty ?? false) &&
          _shouldActivateAndroidDirectUsb(preferredDevice)) {
        final selected = await selectDevice(preferredDevice);
        if (!selected) {
          return false;
        }
      }
    }

    try {
      final result = await _channel.invokeMethod<bool>('setExclusiveDacMode', {
        'enabled': enabled,
      });
      await _refreshAndroidRouteStatus(
        formatOverride: _lastKnownFormat,
        isPlaying: _lastKnownIsPlaying,
        hasActiveSong: _lastKnownHasSong,
      );
      return result ?? true;
    } catch (e) {
      debugPrint('Uac2Service.setBitPerfectEnabled failed: $e');
      return false;
    }
  }

  Future<bool> isBitPerfectEnabled() async {
    final enabled = await _preferencesService.getBitPerfectEnabled();
    if (bitPerfectEnabledNotifier.value != enabled) {
      bitPerfectEnabledNotifier.value = enabled;
    }
    return enabled;
  }

  Future<bool> setExclusiveDacModeEnabled(bool enabled, {bool persist = true}) {
    return setBitPerfectEnabled(enabled, persist: persist);
  }
}

String? _androidRouteWarningMessage(
  Uac2RouteType routeType, {
  required bool preferredUsbDetected,
  required bool directUsbRegistered,
}) {
  if (directUsbRegistered && routeType != Uac2RouteType.externalUsb) {
    return 'An experimental direct USB DAC is registered, but Android still reports ${routeType.name} as the current system route. Direct USB bypasses Android system volume and mixer controls, so the format shown below is requested content format, not verified hardware output.';
  }

  if (preferredUsbDetected && routeType != Uac2RouteType.externalUsb) {
    return 'A preferred USB DAC is attached, but Android does not report it as the current shared route. Direct USB output is only confirmed when the experimental direct path becomes active.';
  }

  switch (routeType) {
    case Uac2RouteType.externalUsb:
      return 'External USB DAC route is active. The format shown below is the track format, not a confirmed DAC output rate. Confirm the DAC indicator because Android may still keep the device locked or resample the stream.';
    case Uac2RouteType.dock:
      return 'Dock audio route is active. The format shown below is the track format, not a confirmed DAC output rate. Confirm the actual output mode on the device.';
    case Uac2RouteType.internalDac:
    case Uac2RouteType.wired:
    case Uac2RouteType.bluetooth:
    case Uac2RouteType.unknown:
      return null;
  }
}

bool _isAndroidStreamingRoute(
  Uac2RouteType routeType, {
  required bool preferredUsbDetected,
  required bool directUsbRegistered,
}) {
  if (directUsbRegistered || preferredUsbDetected) {
    return true;
  }
  return routeType == Uac2RouteType.externalUsb;
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

rust_audio.AudioCapabilityType _audioCapabilityTypeFromString(String value) {
  switch (value) {
    case 'usbDac':
      return rust_audio.AudioCapabilityType.usbDac;
    case 'hiResInternal':
      return rust_audio.AudioCapabilityType.hiResInternal;
    default:
      return rust_audio.AudioCapabilityType.standard;
  }
}

typedef Uac2DeviceInfo = rust_uac2.Uac2DeviceInfo;
typedef Uac2VolumeRange = rust_uac2.Uac2VolumeRange;
typedef Uac2TransferStats = rust_uac2.Uac2TransferStats;
typedef Uac2PipelineInfo = rust_uac2.Uac2PipelineInfo;
typedef Uac2ConnectionState = rust_uac2.Uac2ConnectionState;
typedef Uac2FallbackInfo = rust_uac2.Uac2FallbackInfo;
