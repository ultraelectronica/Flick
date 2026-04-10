import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/models/audio_output_diagnostics.dart';
import 'package:flick/services/uac2_service.dart';
import 'package:flick/services/uac2_preferences_service.dart';
import 'package:flick/providers/player_provider.dart';

final uac2ServiceProvider = Provider<Uac2Service>((ref) {
  return Uac2Service.instance;
});

final uac2AvailableProvider = Provider<bool>((ref) {
  final service = ref.watch(uac2ServiceProvider);
  return service.isAvailable;
});

final uac2DevicesProvider = FutureProvider<List<Uac2DeviceInfo>>((ref) async {
  final service = ref.watch(uac2ServiceProvider);
  return service.listDevices();
});

class Uac2DeviceStatusNotifier extends Notifier<Uac2DeviceStatus?> {
  // Not `late final` — Notifier.build() can be re-invoked when dependencies
  // change, which requires re-assignment.
  late Uac2Service _service;
  late void Function(Uac2DeviceStatus?) _statusCallback;

  @override
  Uac2DeviceStatus? build() {
    _service = ref.watch(uac2ServiceProvider);
    _statusCallback = (status) {
      state = status;
    };
    _service.addStatusListener(_statusCallback);
    ref.onDispose(() => _service.removeStatusListener(_statusCallback));
    return _service.currentDeviceStatus;
  }

  Uac2DeviceStatus? get status => state;

  Future<bool> selectDevice(Uac2DeviceInfo device) async {
    return _service.selectDevice(device);
  }

  Future<bool> startStreaming(Uac2AudioFormat format) async {
    return _service.startStreaming(format);
  }

  Future<bool> stopStreaming() async {
    return _service.stopStreaming();
  }

  Future<void> disconnect() async {
    await _service.disconnect();
  }

  Future<bool> setVolume(double volume) async {
    return _service.setVolume(volume);
  }

  Future<double?> getVolume() async {
    return _service.getVolume();
  }

  Future<bool> setMute(bool muted) async {
    return _service.setMute(muted);
  }

  Future<bool?> getMute() async {
    return _service.getMute();
  }
}

final uac2DeviceStatusProvider =
    NotifierProvider<Uac2DeviceStatusNotifier, Uac2DeviceStatus?>(
      Uac2DeviceStatusNotifier.new,
    );

class SelectedUac2Device extends Notifier<Uac2DeviceInfo?> {
  @override
  Uac2DeviceInfo? build() => null;

  void select(Uac2DeviceInfo? device) {
    state = device;
  }
}

final selectedUac2DeviceProvider =
    NotifierProvider<SelectedUac2Device, Uac2DeviceInfo?>(
      SelectedUac2Device.new,
    );

final uac2DeviceCapabilitiesProvider =
    FutureProvider.family<Uac2DeviceCapabilities?, Uac2DeviceInfo>((
      ref,
      device,
    ) async {
      final service = ref.watch(uac2ServiceProvider);
      return service.getDeviceCapabilities(device);
    });

class Uac2Enabled extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() {
    state = !state;
  }

  void set(bool value) {
    state = value;
  }
}

final uac2EnabledProvider = NotifierProvider<Uac2Enabled, bool>(
  Uac2Enabled.new,
);

/// Whether the Rust audio backend is currently active.
/// Reactively listens to [PlayerService.usingRustBackendNotifier].
final rustBackendActiveProvider = Provider<bool>((ref) {
  final notifier = ref.watch(playerServiceProvider).usingRustBackendNotifier;
  // Bridge ValueNotifier → Riverpod: invalidate this provider when value changes.
  // ref.onDispose ensures the listener is removed on provider teardown / hot-restart.
  void listener() => ref.invalidateSelf();
  notifier.addListener(listener);
  ref.onDispose(() => notifier.removeListener(listener));
  return notifier.value;
});

final currentPlaybackModeProvider = Provider<AudioEngineType>((ref) {
  final notifier = ref
      .watch(playerServiceProvider)
      .selectedPlaybackModeNotifier;
  void listener() => ref.invalidateSelf();
  notifier.addListener(listener);
  ref.onDispose(() => notifier.removeListener(listener));
  return notifier.value;
});

final audioOutputDiagnosticsProvider = Provider<AudioOutputDiagnostics?>((ref) {
  final notifier = ref
      .watch(playerServiceProvider)
      .audioOutputDiagnosticsNotifier;
  void listener() => ref.invalidateSelf();
  notifier.addListener(listener);
  ref.onDispose(() => notifier.removeListener(listener));
  return notifier.value;
});

final uac2BitPerfectIndicatorProvider = Provider<bool>((ref) {
  final diagnostics = ref.watch(audioOutputDiagnosticsProvider);
  return diagnostics?.capabilityFlags.supportsVerifiedBitPerfect == true;
});

final uac2PreferencesServiceProvider = Provider((ref) {
  return Uac2PreferencesService();
});

final uac2AutoConnectProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(uac2PreferencesServiceProvider);
  return service.getAutoConnect();
});

final uac2AutoSelectDeviceProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(uac2PreferencesServiceProvider);
  return service.getAutoSelectDevice();
});

final uac2FormatPreferenceProvider = FutureProvider<Uac2FormatPreference>((
  ref,
) async {
  final service = ref.watch(uac2PreferencesServiceProvider);
  return service.getFormatPreference();
});

final uac2PreferredFormatProvider = FutureProvider<Uac2AudioFormat?>((
  ref,
) async {
  final service = ref.watch(uac2PreferencesServiceProvider);
  return service.loadPreferredFormat();
});

final uac2HiFiModeProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(uac2PreferencesServiceProvider);
  return service.getHiFiModeEnabled();
});

final audioEnginePreferenceProvider = FutureProvider<AudioEnginePreference>((
  ref,
) async {
  final service = ref.watch(uac2PreferencesServiceProvider);
  return service.getAudioEnginePreference();
});

final developerModeEnabledProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(uac2PreferencesServiceProvider);
  return service.getDeveloperModeEnabled();
});

final uac2BitPerfectEnabledProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(uac2PreferencesServiceProvider);
  return service.getBitPerfectEnabled();
});

final uac2ExclusiveDacModeProvider = uac2BitPerfectEnabledProvider;
