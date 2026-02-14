import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flick/src/rust/api/uac2_api.dart' as rust_uac2;

/// Service that wraps the custom UAC 2.0 (USB Audio Class 2.0) API.
///
/// On Android, uses the platform USB Host API via method channel.
/// On other platforms, uses the Rust backend when built with the `uac2` feature.
class Uac2Service {
  Uac2Service._();

  static final Uac2Service instance = Uac2Service._();

  static const _channel = MethodChannel('com.ultraelectronica.flick/uac2');

  /// Whether the UAC 2.0 backend is available on this platform.
  /// On Android: true (USB Host API). Else: true when Rust is built with `uac2`.
  bool get isAvailable {
    if (Platform.isAndroid) return true;
    return rust_uac2.uac2IsAvailable();
  }

  /// Enumerates connected UAC 2.0 devices (DACs/AMPs).
  /// On Android uses the platform channel; otherwise uses Rust.
  Future<List<Uac2DeviceInfo>> listDevices() async {
    if (Platform.isAndroid) return _listDevicesAndroid();
    if (!rust_uac2.uac2IsAvailable()) return [];
    try {
      return rust_uac2.uac2ListDevices();
    } catch (e) {
      debugPrint('Uac2Service.listDevices failed: $e');
      return [];
    }
  }

  Future<List<Uac2DeviceInfo>> _listDevicesAndroid() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('listDevices');
      if (raw == null) return [];
      return raw.map((e) {
        final m = Map<String, dynamic>.from(e as Map<dynamic, dynamic>);
        // On Android, deviceName is the stable id for requestPermission; use as serial fallback.
        final deviceName = m['deviceName'] as String?;
        return Uac2DeviceInfo(
          vendorId: (m['vendorId'] as num?)?.toInt() ?? 0,
          productId: (m['productId'] as num?)?.toInt() ?? 0,
          serial: m['serial'] as String? ?? deviceName,
          productName: m['productName'] as String? ?? 'USB Audio Device',
          manufacturer: m['manufacturer'] as String? ?? '',
        );
      }).toList();
    } catch (e) {
      debugPrint('Uac2Service.listDevices (Android) failed: $e');
      return [];
    }
  }

  /// Returns whether the app has permission to access the given USB device (Android only).
  /// On non-Android platforms returns true when the device is in the list.
  Future<bool> hasPermission(String deviceName) async {
    if (!Platform.isAndroid) return true;
    try {
      final result = await _channel.invokeMethod<bool>('hasPermission', {'deviceName': deviceName});
      return result ?? false;
    } catch (e) {
      debugPrint('Uac2Service.hasPermission failed: $e');
      return false;
    }
  }

  /// Requests permission to access the USB device (Android only).
  /// Shows the system permission dialog. Returns true if granted.
  Future<bool> requestPermission(String deviceName) async {
    if (!Platform.isAndroid) return true;
    try {
      final result = await _channel.invokeMethod<bool>('requestPermission', {'deviceName': deviceName});
      return result ?? false;
    } catch (e) {
      debugPrint('Uac2Service.requestPermission failed: $e');
      return false;
    }
  }
}

/// Re-export the generated device info type for convenience.
typedef Uac2DeviceInfo = rust_uac2.Uac2DeviceInfo;
