import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/src/rust/frb_generated.dart';
import 'package:flick/app/app.dart';
import 'package:flick/data/database.dart';
import 'package:flick/services/permission_service.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/rust_audio_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Rust library (flutter_rust_bridge)
  await RustLib.init();

  // Initialize database FIRST (required by PlayerService)
  await Database.init();

  runApp(const ProviderScope(child: FlickPlayerApp()));

  unawaited(
    PlayerService().initAudio().catchError(
      (Object e) => debugPrint('Eager audio warm-up failed: $e'),
    ),
  );

  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_bootstrapAppAfterFirstFrame());
  });
}

/// Initialize both audio engines (just_audio for Android, Rust engine for desktop).
Future<void> _initAudioEngines() async {
  // Initialize just_audio (used on Android)
  try {
    final playerService = PlayerService();
    await playerService.initAudio();
    debugPrint('just_audio engine initialized successfully');
  } catch (e) {
    debugPrint('Failed to initialize just_audio engine: $e');
    // Continue anyway - the app can still function with degraded audio
  }

  // Initialize Rust audio engine only on desktop platforms.
  try {
    if (Platform.isAndroid || Platform.isIOS) {
      debugPrint('Skipping eager Rust audio engine init on mobile');
      return;
    }
    final rustAudioService = RustAudioService();
    final initialized = await rustAudioService.init();
    if (initialized) {
      debugPrint('Rust audio engine initialized successfully');
    } else {
      debugPrint(
        'Rust audio engine not available (expected on mobile platforms)',
      );
    }
  } catch (e) {
    debugPrint('Failed to initialize Rust audio engine: $e');
    // Continue anyway - Rust engine is only for desktop platforms
  }
}

Future<void> _bootstrapAppAfterFirstFrame() async {
  unawaited(_setOptimalDisplayMode());
  unawaited(
    _requestNotificationPermission().catchError(
      (Object e) => debugPrint('Notification permission request failed: $e'),
    ),
  );

  try {
    await _initAudioEngines();
    await _restoreLastPlayedSong();
  } catch (e) {
    debugPrint('Deferred audio bootstrap failed: $e');
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
