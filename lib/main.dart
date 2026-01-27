import 'package:flutter/material.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/src/rust/frb_generated.dart';
import 'package:flick/app/app.dart';
import 'package:flick/data/database.dart';
import 'package:flick/services/permission_service.dart';
import 'package:flick/services/player_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Rust library (flutter_rust_bridge)
  await RustLib.init();

  // Initialize database FIRST (required by PlayerService)
  await Database.init();

  // Initialize audio engine with just_audio (requires database)
  await _initAudioEngine();

  // Set high refresh rate mode for smoother animations
  await _setOptimalDisplayMode();

  // Request notification permission (required for Android 13+ media controls)
  await _requestNotificationPermission();

  // Restore last played song state
  await _restoreLastPlayedSong();

  runApp(const ProviderScope(child: FlickPlayerApp()));
}

/// Initialize the audio engine with just_audio for gapless playback.
Future<void> _initAudioEngine() async {
  try {
    final playerService = PlayerService();
    await playerService.initAudio();
    debugPrint('Audio engine initialized successfully');
  } catch (e) {
    debugPrint('Failed to initialize audio engine: $e');
    // Continue anyway - the app can still function with degraded audio
  }
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

/// Request notification permission if not already granted.
/// This is required for Android 13+ to show media playback notifications.
Future<void> _requestNotificationPermission() async {
  final permissionService = PermissionService();
  final hasPermission = await permissionService.hasNotificationPermission();
  if (!hasPermission) {
    await permissionService.requestNotificationPermission();
  }
}

/// Restore last played song state from storage.
/// This allows resuming playback from where the user left off.
Future<void> _restoreLastPlayedSong() async {
  try {
    final playerService = PlayerService();
    await playerService.restoreLastPlayed();
  } catch (e) {
    debugPrint('Failed to restore last played song: $e');
  }
}
