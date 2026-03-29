import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/services/uac2_service.dart';
import 'package:flick/services/uac2_preferences_service.dart';

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

class Uac2DeviceStatusNotifier extends ChangeNotifier {
  final Uac2Service _service;
  Uac2DeviceStatus? _status;

  Uac2DeviceStatusNotifier(this._service) {
    _service.addStatusListener(_onStatusChanged);
    _status = _service.currentDeviceStatus;
  }

  Uac2DeviceStatus? get status => _status;

  void _onStatusChanged(Uac2DeviceStatus? status) {
    _status = status;
    notifyListeners();
  }

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

  @override
  void dispose() {
    _service.removeStatusListener(_onStatusChanged);
    super.dispose();
  }
}

final uac2DeviceStatusProvider = Provider<Uac2DeviceStatusNotifier>((ref) {
  final notifier = Uac2DeviceStatusNotifier(ref.watch(uac2ServiceProvider));
  ref.onDispose(() => notifier.dispose());
  return notifier;
});

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

final uac2BitPerfectIndicatorProvider = Provider<bool>((ref) {
  final notifier = ref.watch(uac2DeviceStatusProvider);
  final status = notifier.status;
  if (status == null || status.state != Uac2State.streaming) {
    return false;
  }
  if (status.routeType == Uac2RouteType.externalUsb ||
      status.routeType == Uac2RouteType.dock) {
    return false;
  }
  return true;
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
