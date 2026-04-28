import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/src/rust/frb_generated.dart';
import 'package:flick/app/app.dart';
import 'package:flick/data/database.dart';
import 'package:flick/services/external_playback_service.dart';
import 'package:flick/services/permission_service.dart';
import 'package:flick/services/player_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  await RustLib.init();

  await Database.init();

  final externalPlaybackHandled = await ExternalPlaybackService().initialize();
  if (!externalPlaybackHandled) {
    await _restoreLastPlayedSong();
  }

  runApp(const ProviderScope(child: FlickPlayerApp()));

  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_bootstrapAppAfterFirstFrame());
  });
}

Future<void> _bootstrapAppAfterFirstFrame() async {
  unawaited(_setOptimalDisplayMode());
  unawaited(
    _requestNotificationPermission().catchError(
      (Object e) => debugPrint('Notification permission request failed: $e'),
    ),
  );
  unawaited(
    PlayerService().prepareForAppLaunch().catchError(
      (Object e) => debugPrint('Audio prewarm failed: $e'),
    ),
  );
}

Future<void> _setOptimalDisplayMode() async {
  try {
    await FlutterDisplayMode.setHighRefreshRate();
  } catch (e) {
    debugPrint('Display mode not supported: $e');
  }
}

Future<void> _requestNotificationPermission() async {
  final permissionService = PermissionService();
  final hasPermission = await permissionService.hasNotificationPermission();
  if (!hasPermission) {
    await permissionService.requestNotificationPermission();
  }
}

Future<void> _restoreLastPlayedSong() async {
  try {
    final playerService = PlayerService();
    await playerService.restoreLastPlayed();
  } catch (e) {
    debugPrint('Failed to restore last played song: $e');
  }
}
