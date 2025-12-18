import 'package:flutter/material.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flick/src/rust/frb_generated.dart';
import 'package:flick/app/app.dart';
import 'package:flick/data/database.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Rust library
  await RustLib.init();

  // Initialize database
  await Database.init();

  // Set high refresh rate mode for smoother animations
  await _setOptimalDisplayMode();

  runApp(const FlickPlayerApp());
}

/// Sets the highest available refresh rate mode on Android devices.
/// This significantly improves animation smoothness on 90Hz/120Hz displays.
Future<void> _setOptimalDisplayMode() async {
  try {
    await FlutterDisplayMode.setHighRefreshRate();
  } catch (e) {
    // Silently ignore on unsupported platforms (iOS, Web, etc.)
    debugPrint('Display mode not supported: $e');
  }
}
