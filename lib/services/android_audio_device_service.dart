import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AndroidPlaybackDeviceInfo {
  const AndroidPlaybackDeviceInfo({
    required this.hasUsbDac,
    required this.hasAttachedUac2Device,
    required this.manufacturer,
    required this.model,
    this.routeType,
    this.routeLabel,
  });

  final bool hasUsbDac;
  final bool hasAttachedUac2Device;
  final String manufacturer;
  final String model;
  final String? routeType;
  final String? routeLabel;

  bool get isUsbRoute => routeType == 'usb';
  bool get isInternalRoute => routeType == 'internal';
  bool get isWiredRoute => routeType == 'wired';
  bool get isBluetoothRoute => routeType == 'bluetooth';
  bool get isDockRoute => routeType == 'dock';
  bool get looksLikeUsbAudioRoute {
    final summary = routeSummary.toLowerCase();
    return summary.contains('usb') || summary.contains('dac');
  }

  bool get isLikelyDap {
    final haystack = '${manufacturer.toLowerCase()} ${model.toLowerCase()}';
    const dapKeywords = <String>[
      'hiby',
      'shanling',
      'fiio',
      'ibasso',
      'astell',
      'kann',
      'cayin',
      'walkman',
      'tempotec',
      'luxury precision',
      'luxuryprecision',
    ];
    return dapKeywords.any(haystack.contains);
  }

  bool get isXiaomiDevice {
    final haystack = '${manufacturer.toLowerCase()} ${model.toLowerCase()}';
    return haystack.contains('xiaomi') ||
        haystack.contains('redmi') ||
        haystack.contains('poco') ||
        haystack.contains('miui');
  }

  String get routeSummary => routeLabel ?? routeType ?? 'unknown';

  factory AndroidPlaybackDeviceInfo.fromMap(Map<Object?, Object?> raw) {
    return AndroidPlaybackDeviceInfo(
      hasUsbDac: raw['hasUsbDac'] == true,
      hasAttachedUac2Device:
          raw['hasAttachedUac2Device'] == true || raw['hasUsbDac'] == true,
      manufacturer: raw['manufacturer'] as String? ?? '',
      model: raw['model'] as String? ?? '',
      routeType: raw['routeType'] as String?,
      routeLabel: raw['routeLabel'] as String?,
    );
  }

  static const unknown = AndroidPlaybackDeviceInfo(
    hasUsbDac: false,
    hasAttachedUac2Device: false,
    manufacturer: '',
    model: '',
  );
}

class AndroidAudioDeviceService {
  AndroidAudioDeviceService._();

  static final AndroidAudioDeviceService instance =
      AndroidAudioDeviceService._();

  static const MethodChannel _channel = MethodChannel(
    'com.ultraelectronica.flick/audio_device',
  );

  final ValueNotifier<AndroidPlaybackDeviceInfo> deviceInfoNotifier =
      ValueNotifier(AndroidPlaybackDeviceInfo.unknown);

  bool _channelConfigured = false;
  Future<void>? _initializeInFlight;
  Future<AndroidPlaybackDeviceInfo>? _refreshInFlight;

  Future<void> initialize() async {
    if (!Platform.isAndroid) return;

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

  Future<AndroidPlaybackDeviceInfo> refresh() async {
    if (!Platform.isAndroid) {
      return AndroidPlaybackDeviceInfo.unknown;
    }

    final inFlight = _refreshInFlight;
    if (inFlight != null) {
      return inFlight;
    }

    final future = _refreshInternal();
    _refreshInFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_refreshInFlight, future)) {
        _refreshInFlight = null;
      }
    }
  }

  Future<void> _initializeInternal() async {
    if (!_channelConfigured) {
      _channelConfigured = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'onPlaybackDevicesChanged') {
          debugPrint('[Engine] Audio device change detected');
          await refresh();
        }
      });
    }

    await refresh();
  }

  Future<AndroidPlaybackDeviceInfo> _refreshInternal() async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'getPlaybackDeviceInfo',
      );
      final info = raw == null
          ? AndroidPlaybackDeviceInfo.unknown
          : AndroidPlaybackDeviceInfo.fromMap(raw);
      deviceInfoNotifier.value = info;
      return info;
    } catch (e) {
      debugPrint('AndroidAudioDeviceService.refresh failed: $e');
      deviceInfoNotifier.value = AndroidPlaybackDeviceInfo.unknown;
      return AndroidPlaybackDeviceInfo.unknown;
    }
  }
}
