import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flick/services/uac2_service.dart';

enum Uac2FormatPreference { highestQuality, compatibility, custom }

enum AudioEnginePreference { exoPlayer, rustOboe, isochronousUsb }

class Uac2PreferencesService {
  static final ValueNotifier<bool> developerModeNotifier = ValueNotifier(false);
  static final ValueNotifier<bool> killIsochronousUsbOnQuitNotifier = ValueNotifier(true);
  static const _keySelectedDevice = 'uac2_selected_device';
  static const _keyPreferredFormat = 'uac2_preferred_format';
  static const _keyFormatPreference = 'uac2_format_preference';
  static const _keyHiFiModeEnabled = 'uac2_hifi_mode_enabled';
  static const _keyBitPerfectEnabled = 'uac2_bit_perfect_enabled';
  static const _keyDapBitPerfectEnabled = 'uac2_dap_bit_perfect_enabled';
  static const _keyExclusiveDacModeEnabled = 'uac2_exclusive_dac_mode_enabled';
  static const _keyAudioEnginePreference = 'audio_engine_preference';
  static const _keyDeveloperModeEnabled = 'developer_mode_enabled';
  static const _keyAudioFormatEnabled = 'uac2_audio_format_enabled';
  static const _keyUsbSoftwareVolume = 'uac2_usb_software_volume';
  static const _keyKillIsochronousUsbOnQuit = 'uac2_kill_isochronous_usb_on_quit';

  static bool get isDeveloperModeEnabledSync => developerModeNotifier.value;
  static bool get isKillIsochronousUsbOnQuitSync => killIsochronousUsbOnQuitNotifier.value;

  Future<void> saveSelectedDevice(Uac2DeviceInfo device) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final deviceJson = jsonEncode({
        'vendorId': device.vendorId,
        'productId': device.productId,
        'serial': device.serial,
        'productName': device.productName,
        'manufacturer': device.manufacturer,
        'deviceName': device.deviceName,
      });
      await prefs.setString(_keySelectedDevice, deviceJson);
    } catch (e) {
      debugPrint('Failed to save selected device: $e');
    }
  }

  Future<Uac2DeviceInfo?> loadSelectedDevice() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final deviceJson = prefs.getString(_keySelectedDevice);
      if (deviceJson == null) return null;

      final map = jsonDecode(deviceJson) as Map<String, dynamic>;
      return Uac2DeviceInfo(
        vendorId: map['vendorId'] as int,
        productId: map['productId'] as int,
        serial: map['serial'] as String?,
        productName: map['productName'] as String,
        manufacturer: map['manufacturer'] as String,
        deviceName: map['deviceName'] as String?,
      );
    } catch (e) {
      debugPrint('Failed to load selected device: $e');
      return null;
    }
  }

  Future<void> clearSelectedDevice() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keySelectedDevice);
    } catch (e) {
      debugPrint('Failed to clear selected device: $e');
    }
  }

  Future<void> savePreferredFormat(Uac2AudioFormat format) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final formatJson = jsonEncode(format.toJson());
      await prefs.setString(_keyPreferredFormat, formatJson);
    } catch (e) {
      debugPrint('Failed to save preferred format: $e');
    }
  }

  Future<Uac2AudioFormat?> loadPreferredFormat() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final formatJson = prefs.getString(_keyPreferredFormat);
      if (formatJson == null) return null;

      final map = jsonDecode(formatJson) as Map<String, dynamic>;
      return Uac2AudioFormat.fromJson(map);
    } catch (e) {
      debugPrint('Failed to load preferred format: $e');
      return null;
    }
  }

  Future<void> setHiFiModeEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyHiFiModeEnabled, enabled);
    } catch (e) {
      debugPrint('Failed to save HiFi mode setting: $e');
    }
  }

  Future<bool> getHiFiModeEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyHiFiModeEnabled) ?? false;
    } catch (e) {
      debugPrint('Failed to load HiFi mode setting: $e');
      return false;
    }
  }

  Future<void> setBitPerfectEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyBitPerfectEnabled, enabled);
      await prefs.setBool(_keyExclusiveDacModeEnabled, enabled);
    } catch (e) {
      debugPrint('Failed to save bit-perfect mode setting: $e');
    }
  }

  Future<bool> getBitPerfectEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyBitPerfectEnabled) ?? false;
    } catch (e) {
      debugPrint('Failed to load bit-perfect mode setting: $e');
      return false;
    }
  }

  Future<void> setDapBitPerfectEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyDapBitPerfectEnabled, enabled);
    } catch (e) {
      debugPrint('Failed to save Bit-perfect (DAP Internal) setting: $e');
    }
  }

  Future<bool> getDapBitPerfectEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyDapBitPerfectEnabled) ?? true;
    } catch (e) {
      debugPrint('Failed to load Bit-perfect (DAP Internal) setting: $e');
      return true;
    }
  }

  Future<void> setExclusiveDacModeEnabled(bool enabled) {
    return setBitPerfectEnabled(enabled);
  }

  Future<bool> getExclusiveDacModeEnabled() {
    return getBitPerfectEnabled();
  }

  Future<void> setAudioEnginePreference(
    AudioEnginePreference preference,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyAudioEnginePreference, preference.name);
    } catch (e) {
      debugPrint('Failed to save audio engine preference: $e');
    }
  }

  Future<AudioEnginePreference> getAudioEnginePreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString(_keyAudioEnginePreference);
      if (value == null) return AudioEnginePreference.exoPlayer;

      return AudioEnginePreference.values.firstWhere(
        (engine) => engine.name == value,
        orElse: () => AudioEnginePreference.exoPlayer,
      );
    } catch (e) {
      debugPrint('Failed to load audio engine preference: $e');
      return AudioEnginePreference.exoPlayer;
    }
  }

  Future<void> initializeDeveloperModeCache() async {
    final enabled = await getDeveloperModeEnabled();
    if (developerModeNotifier.value != enabled) {
      developerModeNotifier.value = enabled;
    }
  }

  Future<void> initializeKillIsochronousUsbOnQuitCache() async {
    final enabled = await getKillIsochronousUsbOnQuit();
    if (killIsochronousUsbOnQuitNotifier.value != enabled) {
      killIsochronousUsbOnQuitNotifier.value = enabled;
    }
  }

  Future<void> setDeveloperModeEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyDeveloperModeEnabled, enabled);
      developerModeNotifier.value = enabled;
    } catch (e) {
      debugPrint('Failed to save developer mode setting: $e');
    }
  }

  Future<bool> getDeveloperModeEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool(_keyDeveloperModeEnabled) ?? false;
      if (developerModeNotifier.value != enabled) {
        developerModeNotifier.value = enabled;
      }
      return enabled;
    } catch (e) {
      debugPrint('Failed to load developer mode setting: $e');
      return developerModeNotifier.value;
    }
  }

  Future<void> setAudioFormatEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyAudioFormatEnabled, enabled);
    } catch (e) {
      debugPrint('Failed to save audio format setting: $e');
    }
  }

  Future<bool> getAudioFormatEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyAudioFormatEnabled) ?? true;
    } catch (e) {
      debugPrint('Failed to load audio format setting: $e');
      return true;
    }
  }

  Future<void> setFormatPreference(Uac2FormatPreference preference) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyFormatPreference, preference.name);
    } catch (e) {
      debugPrint('Failed to save format preference: $e');
    }
  }

  Future<void> setUsbSoftwareVolume(double volume) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_keyUsbSoftwareVolume, volume.clamp(0.0, 1.0));
    } catch (e) {
      debugPrint('Failed to save USB software volume: $e');
    }
  }

  Future<double> getUsbSoftwareVolume() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getDouble(_keyUsbSoftwareVolume) ?? 1.0;
    } catch (e) {
      debugPrint('Failed to load USB software volume: $e');
      return 1.0;
    }
  }

  Future<void> setKillIsochronousUsbOnQuit(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyKillIsochronousUsbOnQuit, enabled);
      killIsochronousUsbOnQuitNotifier.value = enabled;
    } catch (e) {
      debugPrint('Failed to save kill Isochronous USB on quit setting: $e');
    }
  }

  Future<bool> getKillIsochronousUsbOnQuit() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool(_keyKillIsochronousUsbOnQuit) ?? true;
      if (killIsochronousUsbOnQuitNotifier.value != enabled) {
        killIsochronousUsbOnQuitNotifier.value = enabled;
      }
      return enabled;
    } catch (e) {
      debugPrint('Failed to load kill Isochronous USB on quit setting: $e');
      return killIsochronousUsbOnQuitNotifier.value;
    }
  }

  Future<Uac2FormatPreference> getFormatPreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString(_keyFormatPreference);
      if (value == null) return Uac2FormatPreference.highestQuality;

      return Uac2FormatPreference.values.firstWhere(
        (e) => e.name == value,
        orElse: () => Uac2FormatPreference.highestQuality,
      );
    } catch (e) {
      debugPrint('Failed to load format preference: $e');
      return Uac2FormatPreference.highestQuality;
    }
  }

  Future<void> clearAllPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keySelectedDevice);
      await prefs.remove(_keyPreferredFormat);
      await prefs.remove(_keyFormatPreference);
      await prefs.remove(_keyHiFiModeEnabled);
      await prefs.remove(_keyBitPerfectEnabled);
      await prefs.remove(_keyDapBitPerfectEnabled);
      await prefs.remove(_keyExclusiveDacModeEnabled);
      await prefs.remove(_keyAudioEnginePreference);
      await prefs.remove(_keyDeveloperModeEnabled);
      await prefs.remove(_keyAudioFormatEnabled);
      await prefs.remove(_keyUsbSoftwareVolume);
      await prefs.remove(_keyKillIsochronousUsbOnQuit);
      developerModeNotifier.value = false;
      killIsochronousUsbOnQuitNotifier.value = true;
    } catch (e) {
      debugPrint('Failed to clear preferences: $e');
    }
  }
}
