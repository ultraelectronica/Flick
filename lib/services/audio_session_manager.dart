import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/services/android_audio_device_service.dart';
import 'package:flick/services/uac2_preferences_service.dart';
import 'package:flick/services/uac2_service.dart';
import 'package:flick/src/rust/api/audio_api.dart' as rust_audio;

typedef AudioSessionSwitchHandler =
    Future<void> Function({
      required AudioEngineType? from,
      required AudioEngineType to,
      required bool initializeNewEngine,
      required String reason,
    });
typedef AudioSessionPlaybackActiveReader = bool Function();

class AudioSessionManager {
  AudioSessionManager({
    AndroidAudioDeviceService? deviceService,
    Uac2PreferencesService? preferencesService,
    Uac2Service? uac2Service,
    required AudioSessionSwitchHandler onSwitchEngine,
    required AudioSessionPlaybackActiveReader isPlaybackActive,
  }) : _deviceService = deviceService ?? AndroidAudioDeviceService.instance,
       _preferencesService = preferencesService ?? Uac2PreferencesService(),
       _uac2Service = uac2Service ?? Uac2Service.instance,
       _onSwitchEngine = onSwitchEngine,
       _isPlaybackActive = isPlaybackActive;

  final AndroidAudioDeviceService _deviceService;
  final Uac2PreferencesService _preferencesService;
  final Uac2Service _uac2Service;
  final AudioSessionSwitchHandler _onSwitchEngine;
  final AudioSessionPlaybackActiveReader _isPlaybackActive;

  final ValueNotifier<AudioEngineType> selectedModeNotifier = ValueNotifier(
    AudioEngineType.normalAndroid,
  );
  final ValueNotifier<AudioEngineType?> initializedModeNotifier = ValueNotifier(
    null,
  );
  final ValueNotifier<String?> fallbackReasonNotifier = ValueNotifier(null);
  final ValueNotifier<rust_audio.AudioCapabilityInfo> capabilityInfoNotifier =
      ValueNotifier(
        const rust_audio.AudioCapabilityInfo(
          capabilities: [rust_audio.AudioCapabilityType.standard],
          routeType: 'unknown',
          routeLabel: null,
          maxSampleRate: null,
        ),
      );

  bool _initialized = false;
  Future<void>? _initializeInFlight;
  Future<void>? _routeSyncInFlight;
  VoidCallback? _deviceInfoListener;
  final Map<String, String> _exclusiveUnavailableUsbDeviceReasons =
      <String, String>{};

  AudioEngineType get selectedMode => selectedModeNotifier.value;
  AudioEngineType? get initializedMode => initializedModeNotifier.value;
  String? get fallbackReason => fallbackReasonNotifier.value;

  void _debugLog(String message) {
    if (Uac2PreferencesService.isDeveloperModeEnabledSync) {
      debugPrint(message);
    }
  }

  Future<void> initialize() async {
    if (_initialized) return;

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

  Future<void> switchMode(
    AudioEngineType mode, {
    bool initializeNewEngine = false,
    String reason = 'manual switch',
  }) async {
    final previousInitialized = initializedMode;
    final selectedChanged = selectedMode != mode;
    final needsInitialization =
        initializeNewEngine && previousInitialized != mode;
    final needsDisposal =
        previousInitialized != null && previousInitialized != mode;

    selectedModeNotifier.value = mode;

    if (!selectedChanged && !needsInitialization && !needsDisposal) {
      return;
    }

    _debugLog(
      '[Session] Switching from ${previousInitialized?.logLabel ?? 'none'} '
      'to ${mode.logLabel} '
      '(${initializeNewEngine ? 'initialize' : 'lazy'}) because $reason',
    );

    if (needsDisposal || needsInitialization) {
      await _onSwitchEngine(
        from: previousInitialized,
        to: mode,
        initializeNewEngine: initializeNewEngine,
        reason: reason,
      );
    }

    initializedModeNotifier.value = initializeNewEngine
        ? mode
        : (previousInitialized == mode ? previousInitialized : null);
  }

  Future<AudioEngineType> resolvePreferredMode({bool refresh = false}) async {
    await initialize();
    return _resolvePreferredMode(refresh: refresh);
  }

  Future<void> recordFallback({
    required AudioEngineType requestedMode,
    required AudioEngineType fallbackMode,
    required String reason,
  }) async {
    fallbackReasonNotifier.value =
        '${requestedMode.logLabel} -> ${fallbackMode.logLabel}: $reason';
    if (selectedMode != fallbackMode) {
      selectedModeNotifier.value = fallbackMode;
    }
    _debugLog('[Session] Fallback: ${fallbackReasonNotifier.value}');
  }

  Future<void> suppressExperimentalUsbForCurrentDevice({
    required String reason,
  }) async {
    final info = await _deviceService.refresh();
    final deviceKey = _currentUsbExperimentalDeviceKey(info);
    if (deviceKey == null) {
      return;
    }

    _exclusiveUnavailableUsbDeviceReasons[deviceKey] = reason;
    if (selectedMode == AudioEngineType.usbDacExperimental) {
      selectedModeNotifier.value = AudioEngineType.normalAndroid;
    }
    _debugLog(
      '[Session] Marking USB_DAC_EXPERIMENTAL unavailable for the current '
      'DAC this session: $reason',
    );
  }

  void clearFallbackReason() {
    if (fallbackReasonNotifier.value != null) {
      fallbackReasonNotifier.value = null;
    }
  }

  Future<void> setHiFiModeEnabled(bool enabled) async {
    await _preferencesService.setHiFiModeEnabled(enabled);
    await _syncRouteSelection(
      reason: enabled ? 'HiFi Mode enabled' : 'HiFi Mode disabled',
    );
  }

  Future<bool> isHiFiModeEnabled() {
    return _preferencesService.getHiFiModeEnabled();
  }

  Future<void> _initializeInternal() async {
    await _preferencesService.initializeDeveloperModeCache();
    await _deviceService.initialize();
    selectedModeNotifier.value = await _resolvePreferredMode();

    _deviceInfoListener ??= () {
      unawaited(_syncRouteSelection(reason: 'audio route change'));
    };
    _deviceService.deviceInfoNotifier.addListener(_deviceInfoListener!);
    _initialized = true;
  }

  Future<void> _syncRouteSelection({required String reason}) async {
    final inFlight = _routeSyncInFlight;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final future = _syncRouteSelectionInternal(reason: reason);
    _routeSyncInFlight = future;
    try {
      await future;
    } finally {
      if (identical(_routeSyncInFlight, future)) {
        _routeSyncInFlight = null;
      }
    }
  }

  Future<void> _syncRouteSelectionInternal({required String reason}) async {
    final desired = await _resolvePreferredMode(refresh: true);
    if (selectedMode == desired) {
      return;
    }

    selectedModeNotifier.value = desired;
    if (_isPlaybackActive() && initializedMode != desired) {
      _debugLog(
        '[Session] Route changed to ${desired.logLabel}; '
        'new engine will attach on the next playback request ($reason)',
      );
    }
  }

  Future<AudioEngineType> _resolvePreferredMode({bool refresh = false}) async {
    final info = refresh
        ? await _deviceService.refresh()
        : _deviceService.deviceInfoNotifier.value;
    final hiFiModeEnabled = await _preferencesService.getHiFiModeEnabled();
    final bitPerfectEnabled = await _preferencesService.getBitPerfectEnabled();
    final audioEnginePreference = await _preferencesService
        .getAudioEnginePreference();
    final capabilityInfo = await _uac2Service.getAndroidAudioCapabilityInfo();
    final dapInfo = await _detectedAndroidDapInfo();
    capabilityInfoNotifier.value = capabilityInfo;
    final capabilityReportsUsb = capabilityInfo.capabilities.contains(
      rust_audio.AudioCapabilityType.usbDac,
    );
    final looksLikeUsbAudioRoute = info.looksLikeUsbAudioRoute;

    if (info.hasAttachedUac2Device ||
        info.hasUsbDac ||
        capabilityReportsUsb ||
        looksLikeUsbAudioRoute) {
      if (!bitPerfectEnabled) {
        _debugLog(
          '[Session] Keeping NORMAL_ANDROID because Bit-perfect USB is '
          'disabled for this session '
          '(${info.routeLabel ?? info.routeType ?? 'unknown'})',
        );
        return AudioEngineType.normalAndroid;
      }
      final suppressedReason = _suppressedReasonForCurrentUsbDevice(info);
      if (suppressedReason != null) {
        _debugLog(
          '[Session] Keeping NORMAL_ANDROID because USB_DAC_EXPERIMENTAL is '
          'unavailable for the current DAC this session ($suppressedReason)',
        );
        return AudioEngineType.normalAndroid;
      }
      _debugLog(
        '[Session] Selected USB_DAC_EXPERIMENTAL because an external USB DAC '
        'is attached (${info.routeLabel ?? info.routeType ?? 'unknown'}; '
        'attachedUac2=${info.hasAttachedUac2Device}; '
        'audioManagerUsb=${info.hasUsbDac}; '
        'capabilityUsb=$capabilityReportsUsb; '
        'routeLooksUsb=$looksLikeUsbAudioRoute)',
      );
      return AudioEngineType.usbDacExperimental;
    }

    final supportsHiResInternal =
        capabilityInfo.capabilities.contains(
          rust_audio.AudioCapabilityType.hiResInternal,
        ) ||
        dapInfo.detected;
    if (audioEnginePreference == AudioEnginePreference.rustOboe) {
      if (hiFiModeEnabled && supportsHiResInternal) {
        _debugLog(
          '[Session] Selected DAP_INTERNAL_HIGH_RES because Rust via Oboe '
          'is preferred and Android reports a higher-capability internal '
          'route (${capabilityInfo.routeType}/${capabilityInfo.routeLabel ?? 'unknown'}; '
          'detectedDap=${dapInfo.brand ?? 'none'})',
        );
        return AudioEngineType.dapInternalHighRes;
      }

      _debugLog(
        '[Session] Selected RUST_OBOE because the user prefers the Rust '
        'Android-managed engine',
      );
      return AudioEngineType.rustOboe;
    }

    if (hiFiModeEnabled && supportsHiResInternal) {
      _debugLog(
        '[Session] Selected DAP_INTERNAL_HIGH_RES because HiFi Mode is '
        'enabled and Android reports a higher-capability internal route '
        '(${capabilityInfo.routeType}/${capabilityInfo.routeLabel ?? 'unknown'}; '
        'detectedDap=${dapInfo.brand ?? 'none'})',
      );
      return AudioEngineType.dapInternalHighRes;
    }

    if (hiFiModeEnabled && !supportsHiResInternal) {
      _debugLog(
        '[Session] HiFi Mode requested, but Android did not report a '
        'high-resolution internal route. Staying on NORMAL_ANDROID.',
      );
    }

    return AudioEngineType.normalAndroid;
  }

  Future<({bool detected, String? brand})> _detectedAndroidDapInfo() async {
    final debugState = await _uac2Service.getAndroidPlaybackDebugState();
    final rustState = _mapValue(debugState?['rustAudioState']);
    final deviceProfile = _mapValue(rustState?['device_profile']);
    final kind = _mapValue(deviceProfile?['kind']);
    final brand = kind?['Dap'];
    return (
      detected: brand is String && brand.isNotEmpty,
      brand: brand is String ? brand : null,
    );
  }

  Map<String, dynamic>? _mapValue(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  }

  String? _suppressedReasonForCurrentUsbDevice(AndroidPlaybackDeviceInfo info) {
    final deviceKey = _currentUsbExperimentalDeviceKey(info);
    if (deviceKey == null) {
      return null;
    }
    return _exclusiveUnavailableUsbDeviceReasons[deviceKey];
  }

  String? _currentUsbExperimentalDeviceKey(AndroidPlaybackDeviceInfo info) {
    if (!(info.hasAttachedUac2Device ||
        info.hasUsbDac ||
        info.looksLikeUsbAudioRoute)) {
      return null;
    }

    final device = _uac2Service.currentDeviceStatus?.device;
    final vendorId = device?.vendorId ?? 0;
    final productId = device?.productId ?? 0;
    if (vendorId != 0 || productId != 0) {
      return 'vid:$vendorId|pid:$productId';
    }

    final productName = _normalizeUsbIdentityToken(device?.productName);
    final manufacturer = _normalizeUsbIdentityToken(device?.manufacturer);
    if (productName.isNotEmpty || manufacturer.isNotEmpty) {
      return 'name:$productName|mfg:$manufacturer';
    }

    final routeSummary = _normalizeUsbIdentityToken(info.routeSummary);
    if (routeSummary.isNotEmpty) {
      return 'route:$routeSummary';
    }

    return null;
  }

  String _normalizeUsbIdentityToken(String? raw) {
    if (raw == null) {
      return '';
    }

    return raw
        .trim()
        .toLowerCase()
        .replaceFirst(RegExp(r'^usb[- ]audio\s*-\s*'), '')
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  void dispose() {
    final listener = _deviceInfoListener;
    if (listener != null) {
      _deviceService.deviceInfoNotifier.removeListener(listener);
    }
    _deviceInfoListener = null;
    selectedModeNotifier.dispose();
    initializedModeNotifier.dispose();
    fallbackReasonNotifier.dispose();
    capabilityInfoNotifier.dispose();
  }
}
