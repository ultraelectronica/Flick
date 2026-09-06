import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flick/services/uac2_service.dart';
import 'package:flick/core/utils/dev_log.dart';
import 'package:flick/src/rust/audio/engine.dart' show AudioApiPreference;

enum Uac2FormatPreference { highestQuality, compatibility, custom }

enum AudioEnginePreference { exoPlayer, rustOboe, isochronousUsb }

enum DsdOutputMode { auto, forcePcm, forceDop, native }

/// Per-device field-tuning override for native-DSD wire byte order (DSD_U32 packing).
enum DsdByteOrderOverride { auto, littleEndian, bigEndian }

/// Wire-packing variant for the DAP-internal native-DSD shim transport
/// (bit order + subslot endianness inside each subslot).
enum DsdWireVariant { auto, beMsb, leMsb, beLsb, leLsb }

/// Wire byte grouping (subslot width) for the DAP-internal native-DSD shim
/// transport: how many consecutive DSD bytes per channel form one subslot.
enum DsdWireGrouping { auto, u32, u16, u8 }

class Uac2PreferencesService {
  static final ValueNotifier<bool> developerModeNotifier = ValueNotifier(false);
  static final ValueNotifier<bool> killIsochronousUsbOnQuitNotifier = ValueNotifier(true);
  static final ValueNotifier<DsdOutputMode> dsdOutputModeNotifier = ValueNotifier(DsdOutputMode.auto);
  static final ValueNotifier<DsdByteOrderOverride> dsdByteOrderOverrideNotifier = ValueNotifier(DsdByteOrderOverride.auto);
  static final ValueNotifier<int?> dsdSubslotOverrideNotifier = ValueNotifier(null);
  static final ValueNotifier<DsdWireVariant> dsdWireVariantNotifier = ValueNotifier(DsdWireVariant.auto);
  static final ValueNotifier<DsdWireGrouping> dsdWireGroupingNotifier = ValueNotifier(DsdWireGrouping.auto);
  static const _keySelectedDevice = 'uac2_selected_device';
  static const _keyPreferredFormat = 'uac2_preferred_format';
  static const _keyFormatPreference = 'uac2_format_preference';
  static const _keyHiFiModeEnabled = 'uac2_hifi_mode_enabled';
  static const _keyBitPerfectEnabled = 'uac2_bit_perfect_enabled';
  static const _keyDapBitPerfectEnabled = 'uac2_dap_bit_perfect_enabled';
  static const _key432HzTuningEnabled = 'uac2_432hz_tuning_enabled';
  static const _keyExclusiveDacModeEnabled = 'uac2_exclusive_dac_mode_enabled';
  static const _keyAudioEnginePreference = 'audio_engine_preference';
  static const _keyAndroidAudioApi = 'android_audio_api';
  static const _keyDeveloperModeEnabled = 'developer_mode_enabled';
  static const _keyAudioFormatEnabled = 'uac2_audio_format_enabled';
  static const _keyUsbSoftwareVolume = 'uac2_usb_software_volume';
  static const _keyKillIsochronousUsbOnQuit = 'uac2_kill_isochronous_usb_on_quit';
  static const _keyGaplessPlaybackEnabled = 'gapless_playback_enabled';
  static const _keyDuckOnInterruption = 'duck_on_interruption_enabled';
  static const _keyDsdOutputMode = 'dsd_output_mode';
  static const _keyAutoSwitchDsdForVolume = 'auto_switch_dsd_for_volume';
  static const _keyDsdByteOrderOverride = 'dsd_byte_order_override';
  static const _keyDsdSubslotOverride = 'dsd_subslot_override';
  static const _keyDsdWireVariant = 'dsd_wire_variant';
  static const _keyDsdWireGrouping = 'dsd_wire_grouping';

  static bool get isDeveloperModeEnabledSync => developerModeNotifier.value;
  static bool get isKillIsochronousUsbOnQuitSync => killIsochronousUsbOnQuitNotifier.value;
  static DsdOutputMode get dsdOutputModeSync => dsdOutputModeNotifier.value;
  static DsdByteOrderOverride get dsdByteOrderOverrideSync => dsdByteOrderOverrideNotifier.value;
  static int? get dsdSubslotOverrideSync => dsdSubslotOverrideNotifier.value;
  static DsdWireVariant get dsdWireVariantSync => dsdWireVariantNotifier.value;
  static DsdWireGrouping get dsdWireGroupingSync => dsdWireGroupingNotifier.value;
  static final ValueNotifier<bool> autoSwitchDsdForVolumeNotifier = ValueNotifier(false);
  static bool get autoSwitchDsdForVolumeSync => autoSwitchDsdForVolumeNotifier.value;
  static final ValueNotifier<bool> tuning432HzNotifier = ValueNotifier(false);
  static bool get is432HzTuningEnabledSync => tuning432HzNotifier.value;
  static final ValueNotifier<bool> btLowLatencyModeNotifier = ValueNotifier(false);
  static bool get isBtLowLatencyModeSync => btLowLatencyModeNotifier.value;
  static const _keyBtLowLatencyMode = 'bt_low_latency_mode';

  static final ValueNotifier<bool> btHiResDirectNotifier = ValueNotifier(false);
  static bool get isBtHiResDirectSync => btHiResDirectNotifier.value;
  static const _keyBtHiResDirect = 'bt_hires_direct';

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
      devLog('Failed to save selected device: $e');
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
      devLog('Failed to load selected device: $e');
      return null;
    }
  }

  Future<void> clearSelectedDevice() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keySelectedDevice);
    } catch (e) {
      devLog('Failed to clear selected device: $e');
    }
  }

  Future<void> savePreferredFormat(Uac2AudioFormat format) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final formatJson = jsonEncode(format.toJson());
      await prefs.setString(_keyPreferredFormat, formatJson);
    } catch (e) {
      devLog('Failed to save preferred format: $e');
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
      devLog('Failed to load preferred format: $e');
      return null;
    }
  }

  Future<void> setHiFiModeEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyHiFiModeEnabled, enabled);
    } catch (e) {
      devLog('Failed to save HiFi mode setting: $e');
    }
  }

  Future<bool> getHiFiModeEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyHiFiModeEnabled) ?? false;
    } catch (e) {
      devLog('Failed to load HiFi mode setting: $e');
      return false;
    }
  }

  Future<void> setBitPerfectEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyBitPerfectEnabled, enabled);
      await prefs.setBool(_keyExclusiveDacModeEnabled, enabled);
    } catch (e) {
      devLog('Failed to save bit-perfect mode setting: $e');
    }
  }

  Future<bool> getBitPerfectEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyBitPerfectEnabled) ?? false;
    } catch (e) {
      devLog('Failed to load bit-perfect mode setting: $e');
      return false;
    }
  }

  Future<void> setDapBitPerfectEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyDapBitPerfectEnabled, enabled);
    } catch (e) {
      devLog('Failed to save Bit-perfect (DAP Internal) setting: $e');
    }
  }

  Future<bool> getDapBitPerfectEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyDapBitPerfectEnabled) ?? true;
    } catch (e) {
      devLog('Failed to load Bit-perfect (DAP Internal) setting: $e');
      return true;
    }
  }

  Future<void> set432HzTuningEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key432HzTuningEnabled, enabled);
      tuning432HzNotifier.value = enabled;
    } catch (e) {
      devLog('Failed to save 432 Hz tuning setting: $e');
    }
  }

  Future<bool> get432HzTuningEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool(_key432HzTuningEnabled) ?? false;
      if (tuning432HzNotifier.value != enabled) {
        tuning432HzNotifier.value = enabled;
      }
      return enabled;
    } catch (e) {
      devLog('Failed to load 432 Hz tuning setting: $e');
      return tuning432HzNotifier.value;
    }
  }

  Future<void> initialize432HzTuningCache() async {
    final enabled = await get432HzTuningEnabled();
    if (tuning432HzNotifier.value != enabled) {
      tuning432HzNotifier.value = enabled;
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
      devLog('Failed to save audio engine preference: $e');
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
      devLog('Failed to load audio engine preference: $e');
      return AudioEnginePreference.exoPlayer;
    }
  }

  Future<void> setAndroidAudioApi(AudioApiPreference preference) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyAndroidAudioApi, preference.name);
    } catch (e) {
      devLog('Failed to save Android audio API preference: $e');
    }
  }

  Future<AudioApiPreference> getAndroidAudioApi() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString(_keyAndroidAudioApi);
      if (value == null) return AudioApiPreference.auto;
      return AudioApiPreference.values.firstWhere(
        (api) => api.name == value,
        orElse: () => AudioApiPreference.auto,
      );
    } catch (e) {
      devLog('Failed to load Android audio API preference: $e');
      return AudioApiPreference.auto;
    }
  }

  Future<void> initializeDeveloperModeCache() async {
    final enabled = await getDeveloperModeEnabled();
    if (developerModeNotifier.value != enabled) {
      developerModeNotifier.value = enabled;
    }
    await Uac2Service.instance.syncDeveloperModeToNative();
  }

  Future<void> initializeKillIsochronousUsbOnQuitCache() async {
    final enabled = await getKillIsochronousUsbOnQuit();
    if (killIsochronousUsbOnQuitNotifier.value != enabled) {
      killIsochronousUsbOnQuitNotifier.value = enabled;
    }
  }

  // ponytail: getters hydrate their notifiers as a side effect; this just gives
  // startup a named entry point so the BT toggles survive an app restart.
  Future<void> initializeBtFlagsCache() async {
    await getBtHiResDirect();
    await getBtLowLatencyMode();
  }

  Future<void> setDeveloperModeEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyDeveloperModeEnabled, enabled);
      developerModeNotifier.value = enabled;
      await Uac2Service.instance.syncDeveloperModeToNative();
    } catch (e) {
      devLog('Failed to save developer mode setting: $e');
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
      devLog('Failed to load developer mode setting: $e');
      return developerModeNotifier.value;
    }
  }

  Future<void> setAudioFormatEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyAudioFormatEnabled, enabled);
    } catch (e) {
      devLog('Failed to save audio format setting: $e');
    }
  }

  Future<bool> getAudioFormatEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyAudioFormatEnabled) ?? true;
    } catch (e) {
      devLog('Failed to load audio format setting: $e');
      return true;
    }
  }

  Future<void> setFormatPreference(Uac2FormatPreference preference) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyFormatPreference, preference.name);
    } catch (e) {
      devLog('Failed to save format preference: $e');
    }
  }

  Future<void> setUsbSoftwareVolume(double volume) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_keyUsbSoftwareVolume, volume.clamp(0.0, 1.0));
    } catch (e) {
      devLog('Failed to save USB software volume: $e');
    }
  }

  Future<double> getUsbSoftwareVolume() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getDouble(_keyUsbSoftwareVolume) ?? 1.0;
    } catch (e) {
      devLog('Failed to load USB software volume: $e');
      return 1.0;
    }
  }

  Future<bool> hasUsbSoftwareVolume() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.containsKey(_keyUsbSoftwareVolume);
    } catch (e) {
      devLog('Failed to check USB software volume key: $e');
      return false;
    }
  }

  Future<void> setKillIsochronousUsbOnQuit(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyKillIsochronousUsbOnQuit, enabled);
      killIsochronousUsbOnQuitNotifier.value = enabled;
    } catch (e) {
      devLog('Failed to save kill Isochronous USB on quit setting: $e');
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
      devLog('Failed to load kill Isochronous USB on quit setting: $e');
      return killIsochronousUsbOnQuitNotifier.value;
    }
  }

  Future<void> setGaplessPlaybackEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyGaplessPlaybackEnabled, enabled);
    } catch (e) {
      devLog('Failed to save gapless playback setting: $e');
    }
  }

  Future<bool> getGaplessPlaybackEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyGaplessPlaybackEnabled) ?? true;
    } catch (e) {
      devLog('Failed to load gapless playback setting: $e');
      return true;
    }
  }

  Future<bool> getDuckOnInterruption() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyDuckOnInterruption) ?? true;
    } catch (e) {
      devLog('Failed to load duck-on-interruption setting: $e');
      return true;
    }
  }

  Future<void> setDuckOnInterruption(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyDuckOnInterruption, enabled);
    } catch (e) {
      devLog('Failed to save duck-on-interruption setting: $e');
    }
  }

  Future<void> setBtLowLatencyMode(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyBtLowLatencyMode, enabled);
      btLowLatencyModeNotifier.value = enabled;
    } catch (e) {
      devLog('Failed to save BT low-latency setting: $e');
    }
  }

  Future<bool> getBtLowLatencyMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool(_keyBtLowLatencyMode) ?? false;
      if (btLowLatencyModeNotifier.value != enabled) {
        btLowLatencyModeNotifier.value = enabled;
      }
      return enabled;
    } catch (e) {
      devLog('Failed to load BT low-latency setting: $e');
      return false;
    }
  }

  Future<void> setBtHiResDirect(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyBtHiResDirect, enabled);
      btHiResDirectNotifier.value = enabled;
    } catch (e) {
      devLog('Failed to save BT hi-res direct setting: $e');
    }
  }

  Future<bool> getBtHiResDirect() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool(_keyBtHiResDirect) ?? false;
      if (btHiResDirectNotifier.value != enabled) {
        btHiResDirectNotifier.value = enabled;
      }
      return enabled;
    } catch (e) {
      devLog('Failed to load BT hi-res direct setting: $e');
      return false;
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
      devLog('Failed to load format preference: $e');
      return Uac2FormatPreference.highestQuality;
    }
  }

  Future<void> setDsdOutputMode(DsdOutputMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyDsdOutputMode, mode.name);
      dsdOutputModeNotifier.value = mode;
    } catch (e) {
      devLog('Failed to save DSD output mode: $e');
    }
  }

  Future<DsdOutputMode> getDsdOutputMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString(_keyDsdOutputMode);
      final mode = value == null
          ? DsdOutputMode.auto
          : DsdOutputMode.values.firstWhere(
              (e) => e.name == value,
              orElse: () => DsdOutputMode.auto,
            );
      dsdOutputModeNotifier.value = mode;
      return mode;
    } catch (e) {
      devLog('Failed to load DSD output mode: $e');
      return DsdOutputMode.auto;
    }
  }

  Future<void> setDsdByteOrderOverride(DsdByteOrderOverride value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyDsdByteOrderOverride, value.name);
      dsdByteOrderOverrideNotifier.value = value;
    } catch (e) {
      devLog('Failed to save DSD byte order override: $e');
    }
  }

  Future<DsdByteOrderOverride> getDsdByteOrderOverride() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString(_keyDsdByteOrderOverride);
      final mode = value == null
          ? DsdByteOrderOverride.auto
          : DsdByteOrderOverride.values.firstWhere(
              (e) => e.name == value,
              orElse: () => DsdByteOrderOverride.auto,
            );
      dsdByteOrderOverrideNotifier.value = mode;
      return mode;
    } catch (e) {
      devLog('Failed to load DSD byte order override: $e');
      return DsdByteOrderOverride.auto;
    }
  }

  /// Set the DAP native-DSD wire-packing variant (bit order + subslot
  /// endianness). Wrong variant = hiss/static on DAPs; calibrate per device.
  Future<void> setDsdWireVariant(DsdWireVariant value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyDsdWireVariant, value.name);
      dsdWireVariantNotifier.value = value;
    } catch (e) {
      devLog('Failed to save DSD wire variant: $e');
    }
  }

  Future<DsdWireVariant> getDsdWireVariant() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString(_keyDsdWireVariant);
      final variant = value == null
          ? DsdWireVariant.auto
          : DsdWireVariant.values.firstWhere(
              (e) => e.name == value,
              orElse: () => DsdWireVariant.auto,
            );
      dsdWireVariantNotifier.value = variant;
      return variant;
    } catch (e) {
      devLog('Failed to load DSD wire variant: $e');
      return DsdWireVariant.auto;
    }
  }

  /// Set the DAP native-DSD wire grouping (subslot width). Wrong grouping =
  /// hiss regardless of bit order; calibrate per device.
  Future<void> setDsdWireGrouping(DsdWireGrouping value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyDsdWireGrouping, value.name);
      dsdWireGroupingNotifier.value = value;
    } catch (e) {
      devLog('Failed to save DSD wire grouping: $e');
    }
  }

  Future<DsdWireGrouping> getDsdWireGrouping() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString(_keyDsdWireGrouping);
      final grouping = value == null
          ? DsdWireGrouping.auto
          : DsdWireGrouping.values.firstWhere(
              (e) => e.name == value,
              orElse: () => DsdWireGrouping.auto,
            );
      dsdWireGroupingNotifier.value = grouping;
      return grouping;
    } catch (e) {
      devLog('Failed to load DSD wire grouping: $e');
      return DsdWireGrouping.auto;
    }
  }

  /// Force a native-DSD subslot size (1=U8, 2=U16, 4=U32). Pass null for auto.
  Future<void> setDsdSubslotOverride(int? value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_keyDsdSubslotOverride, value ?? 0);
      dsdSubslotOverrideNotifier.value = value;
    } catch (e) {
      devLog('Failed to save DSD subslot override: $e');
    }
  }

  Future<int?> getDsdSubslotOverride() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getInt(_keyDsdSubslotOverride) ?? 0;
      final value = stored == 0 ? null : stored;
      dsdSubslotOverrideNotifier.value = value;
      return value;
    } catch (e) {
      devLog('Failed to load DSD subslot override: $e');
      return null;
    }
  }

  Future<void> setAutoSwitchDsdForVolume(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyAutoSwitchDsdForVolume, value);
      autoSwitchDsdForVolumeNotifier.value = value;
    } catch (e) {
      devLog('Failed to save auto-switch DSD for volume: $e');
    }
  }

  Future<bool> getAutoSwitchDsdForVolume() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getBool(_keyAutoSwitchDsdForVolume) ?? false;
      autoSwitchDsdForVolumeNotifier.value = value;
      return value;
    } catch (e) {
      devLog('Failed to load auto-switch DSD for volume: $e');
      return false;
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
      await prefs.remove(_key432HzTuningEnabled);
      await prefs.remove(_keyExclusiveDacModeEnabled);
await prefs.remove(_keyAudioEnginePreference);
    await prefs.remove(_keyAndroidAudioApi);
    await prefs.remove(_keyDeveloperModeEnabled);
      await prefs.remove(_keyAudioFormatEnabled);
      await prefs.remove(_keyUsbSoftwareVolume);
    await prefs.remove(_keyKillIsochronousUsbOnQuit);
    await prefs.remove(_keyGaplessPlaybackEnabled);
    await prefs.remove(_keyDuckOnInterruption);
    await prefs.remove(_keyDsdOutputMode);
    await prefs.remove(_keyAutoSwitchDsdForVolume);
    await prefs.remove(_keyBtLowLatencyMode);
    await prefs.remove(_keyBtHiResDirect);
    await prefs.remove(_keyDsdByteOrderOverride);
    await prefs.remove(_keyDsdSubslotOverride);
    await prefs.remove(_keyDsdWireVariant);
    await prefs.remove(_keyDsdWireGrouping);
      dsdOutputModeNotifier.value = DsdOutputMode.auto;
      dsdByteOrderOverrideNotifier.value = DsdByteOrderOverride.auto;
      dsdSubslotOverrideNotifier.value = null;
      dsdWireVariantNotifier.value = DsdWireVariant.auto;
      dsdWireGroupingNotifier.value = DsdWireGrouping.auto;
      developerModeNotifier.value = false;
      killIsochronousUsbOnQuitNotifier.value = true;
      tuning432HzNotifier.value = false;
      btLowLatencyModeNotifier.value = false;
      btHiResDirectNotifier.value = false;
    } catch (e) {
      devLog('Failed to clear preferences: $e');
    }
  }
}
