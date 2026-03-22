import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flick/services/uac2_service.dart';

class Uac2PreferencesService {
  static const _keySelectedDevice = 'uac2_selected_device';
  static const _keyAutoConnect = 'uac2_auto_connect';
  static const _keyPreferredFormat = 'uac2_preferred_format';

  Future<void> saveSelectedDevice(Uac2DeviceInfo device) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final deviceJson = jsonEncode({
        'vendorId': device.vendorId,
        'productId': device.productId,
        'serial': device.serial,
        'productName': device.productName,
        'manufacturer': device.manufacturer,
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

  Future<void> setAutoConnect(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyAutoConnect, enabled);
    } catch (e) {
      debugPrint('Failed to save auto-connect setting: $e');
    }
  }

  Future<bool> getAutoConnect() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyAutoConnect) ?? false;
    } catch (e) {
      debugPrint('Failed to load auto-connect setting: $e');
      return false;
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
}
