import 'dart:async';

import 'package:flutter/foundation.dart';
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
import 'package:flick/services/uac2_service.dart';
import 'package:flick/core/utils/app_log.dart';
import 'package:flick/core/utils/dev_log.dart';
import 'package:flick/src/rust/api/logging.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  FlutterError.onError = (details) {
    AppLog.instance.add(
      '${details.exception}\n${details.stack}',
      source: LogSource.crash,
    );
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.instance.add('$error\n$stack', source: LogSource.platform);
    return true;
  };

  await RustLib.init();
  _subscribeRustLogs();

  await Database.init();

  final externalPlaybackHandled = await ExternalPlaybackService().initialize();
  if (!externalPlaybackHandled) {
    await _restoreLastPlayedSong();
  }

  runZonedGuarded(() {
    runApp(const ProviderScope(child: FlickPlayerApp()));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_bootstrapAppAfterFirstFrame());
    });
  }, (error, stack) {
    AppLog.instance.add('$error\n$stack', source: LogSource.zone);
  });
}

void _subscribeRustLogs() {
  registerLogSink().listen(
    (msg) => AppLog.instance.add(msg, source: LogSource.rust),
    onError: (Object e) =>
        AppLog.instance.add('rust log stream error: $e', source: LogSource.rust),
  );
}

Future<void> _bootstrapAppAfterFirstFrame() async {
  unawaited(_setOptimalDisplayMode());
  unawaited(
    _requestNotificationPermission().catchError(
      (Object e) => devLog('Notification permission request failed: $e'),
    ),
  );
  unawaited(
    Uac2Service.instance
        .initializeAndroidRouteMonitoring()
        .catchError((Object e) => devLog('USB route probe failed: $e')),
  );
  unawaited(
    PlayerService().prepareForAppLaunch().catchError(
      (Object e) => devLog('Audio prewarm failed: $e'),
    ),
  );
}

Future<void> _setOptimalDisplayMode() async {
  try {
    await FlutterDisplayMode.setHighRefreshRate();
  } catch (e) {
    devLog('Display mode not supported: $e');
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
    await playerService.restorePlaybackModes();
    await playerService.restoreLastPlayed();
  } catch (e) {
    devLog('Failed to restore last played song: $e');
  }
}
