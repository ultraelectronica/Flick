import 'package:flutter/foundation.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';

class DisplayModeService {
  static final DisplayModeService _instance = DisplayModeService._internal();
  factory DisplayModeService() => _instance;
  DisplayModeService._internal();

  List<DisplayMode> _availableModes = [];
  DisplayMode? _currentMode;
  DisplayMode? _preferredMode;

  List<DisplayMode> get availableModes => _availableModes;
  DisplayMode? get currentMode => _currentMode;
  DisplayMode? get preferredMode => _preferredMode;

  bool get isSupported => defaultTargetPlatform == TargetPlatform.android;

  Future<void> initialize() async {
    if (!isSupported) return;
    try {
      _availableModes = await FlutterDisplayMode.supported;
      _currentMode = await FlutterDisplayMode.active;
      _preferredMode = await FlutterDisplayMode.preferred;
    } catch (e) {
      debugPrint('Failed to initialize display modes: $e');
    }
  }

  Future<void> setHighRefreshRate() async {
    if (!isSupported) return;
    try {
      await FlutterDisplayMode.setHighRefreshRate();
      _currentMode = await FlutterDisplayMode.active;
    } catch (e) {
      debugPrint('Failed to set high refresh rate: $e');
    }
  }

  Future<void> setLowRefreshRate() async {
    if (!isSupported) return;
    try {
      await FlutterDisplayMode.setLowRefreshRate();
      _currentMode = await FlutterDisplayMode.active;
    } catch (e) {
      debugPrint('Failed to set low refresh rate: $e');
    }
  }

  Future<void> setPreferredMode(DisplayMode mode) async {
    if (!isSupported) return;
    try {
      await FlutterDisplayMode.setPreferredMode(mode);
      _currentMode = await FlutterDisplayMode.active;
      _preferredMode = mode;
    } catch (e) {
      debugPrint('Failed to set preferred mode: $e');
    }
  }

  DisplayMode? get highestRefreshRateMode {
    if (_availableModes.isEmpty) return null;
    return _availableModes.reduce(
      (a, b) => a.refreshRate > b.refreshRate ? a : b,
    );
  }

  DisplayMode? get highestResolutionMode {
    if (_availableModes.isEmpty) return null;
    return _availableModes.reduce((a, b) {
      final aPixels = (a.width * a.height);
      final bPixels = (b.width * b.height);
      return aPixels > bPixels ? a : b;
    });
  }

  DisplayMode? get optimalMode {
    if (_availableModes.isEmpty) return null;
    return _availableModes.reduce((a, b) {
      final aScore = a.refreshRate * (a.width * a.height);
      final bScore = b.refreshRate * (b.width * b.height);
      return aScore > bScore ? a : b;
    });
  }
}
