import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/services/android_audio_device_service.dart';
import 'package:flick/services/uac2_preferences_service.dart';

typedef AudioEngineSwitchHandler =
    Future<void> Function({
      required AudioEngineType? from,
      required AudioEngineType to,
      required bool initializeNewEngine,
      required String reason,
    });
typedef AudioEnginePlaybackActiveReader = bool Function();

class AudioRouteManager {
  AudioRouteManager({
    AndroidAudioDeviceService? deviceService,
    Uac2PreferencesService? preferencesService,
    required AudioEngineSwitchHandler onSwitchEngine,
    required AudioEnginePlaybackActiveReader isPlaybackActive,
  }) : _deviceService = deviceService ?? AndroidAudioDeviceService.instance,
       _preferencesService = preferencesService ?? Uac2PreferencesService(),
       _onSwitchEngine = onSwitchEngine,
       _isPlaybackActive = isPlaybackActive;

  final AndroidAudioDeviceService _deviceService;
  final Uac2PreferencesService _preferencesService;
  final AudioEngineSwitchHandler _onSwitchEngine;
  final AudioEnginePlaybackActiveReader _isPlaybackActive;

  final ValueNotifier<AudioEngineType> selectedEngineNotifier = ValueNotifier(
    AudioEngineType.android,
  );
  final ValueNotifier<AudioEngineType?> initializedEngineNotifier =
      ValueNotifier(null);

  bool _initialized = false;
  Future<void>? _initializeInFlight;
  Future<void>? _routeSyncInFlight;
  VoidCallback? _deviceInfoListener;

  AudioEngineType get selectedEngineType => selectedEngineNotifier.value;
  AudioEngineType? get initializedEngineType => initializedEngineNotifier.value;

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

  Future<void> switchEngine(
    AudioEngineType type, {
    bool initializeNewEngine = false,
    String reason = 'manual switch',
  }) async {
    final previousInitialized = initializedEngineType;
    final selectedChanged = selectedEngineType != type;
    final needsInitialization =
        initializeNewEngine && previousInitialized != type;
    final needsDisposal =
        previousInitialized != null && previousInitialized != type;

    selectedEngineNotifier.value = type;

    if (!selectedChanged && !needsInitialization && !needsDisposal) {
      return;
    }

    final fromLabel = previousInitialized?.name ?? 'none';
    debugPrint(
      '[Engine] Switching from $fromLabel to ${type.name}'
      ' (${initializeNewEngine ? 'initialize' : 'lazy'})'
      ' because $reason',
    );

    if (needsDisposal || needsInitialization) {
      await _onSwitchEngine(
        from: previousInitialized,
        to: type,
        initializeNewEngine: initializeNewEngine,
        reason: reason,
      );
    }

    initializedEngineNotifier.value = initializeNewEngine
        ? type
        : (previousInitialized == type ? previousInitialized : null);
  }

  Future<AudioEngineType> resolvePreferredEngineType({
    bool refresh = false,
  }) async {
    await initialize();
    return _resolvePreferredEngineType(refresh: refresh);
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
    await _deviceService.initialize();
    selectedEngineNotifier.value = await _resolvePreferredEngineType();

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
    final desired = await _resolvePreferredEngineType(refresh: true);
    if (selectedEngineType == desired) {
      return;
    }

    selectedEngineNotifier.value = desired;
    if (_isPlaybackActive() && initializedEngineType != desired) {
      debugPrint(
        '[Engine] Route changed to ${desired.name}; '
        'new engine will attach on the next playback request ($reason)',
      );
    }
  }

  Future<AudioEngineType> _resolvePreferredEngineType({
    bool refresh = false,
  }) async {
    final info = refresh
        ? await _deviceService.refresh()
        : _deviceService.deviceInfoNotifier.value;
    final hiFiModeEnabled = await _preferencesService.getHiFiModeEnabled();

    if (info.hasUsbDac) {
      return AudioEngineType.usb;
    }

    if (hiFiModeEnabled) {
      debugPrint(
        '[Engine] HiFi Mode requested on a non-USB route; '
        'staying on Android (${info.routeType ?? 'unknown'})',
      );
    }

    // The Rust engine is USB-DAC-only. Speaker, Bluetooth, wired, and
    // internal DAP routes always stay on the Android engine.
    return AudioEngineType.android;
  }

  void dispose() {
    final listener = _deviceInfoListener;
    if (listener != null) {
      _deviceService.deviceInfoNotifier.removeListener(listener);
    }
    _deviceInfoListener = null;
    selectedEngineNotifier.dispose();
    initializedEngineNotifier.dispose();
  }
}
