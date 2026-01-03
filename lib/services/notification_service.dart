import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flick/models/song.dart';

/// Flutter service to communicate with native Android notification service.
/// Handles media playback notifications with controls.
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  static const _channel = MethodChannel('com.ultraelectronica.flick/player');

  bool _isNotificationVisible = false;
  bool get isNotificationVisible => _isNotificationVisible;

  /// Initialize the notification service and set up method call handler
  /// for receiving commands from the notification buttons.
  void init({
    required VoidCallback onTogglePlayPause,
    required VoidCallback onNext,
    required VoidCallback onPrevious,
    required VoidCallback onStop,
    required Function(Duration) onSeek,
  }) {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'togglePlayPause':
          onTogglePlayPause();
          break;
        case 'play':
          onTogglePlayPause(); // Will resume if paused
          break;
        case 'pause':
          onTogglePlayPause(); // Will pause if playing
          break;
        case 'next':
          onNext();
          break;
        case 'previous':
          onPrevious();
          break;
        case 'stop':
          onStop();
          break;
        case 'seek':
          final position = call.arguments['position'] as int?;
          if (position != null) {
            onSeek(Duration(milliseconds: position));
          }
          break;
      }
    });
  }

  /// Show or update the notification with song information.
  Future<void> showNotification({
    required Song song,
    required bool isPlaying,
  }) async {
    try {
      await _channel.invokeMethod('showNotification', {
        'title': song.title,
        'artist': song.artist,
        'albumArtPath': song.albumArt,
        'isPlaying': isPlaying,
      });
      _isNotificationVisible = true;
    } catch (e) {
      debugPrint('Failed to show notification: $e');
    }
  }

  /// Update only the playback state (play/pause button) in the notification.
  Future<void> updatePlaybackState({required bool isPlaying}) async {
    if (!_isNotificationVisible) return;

    try {
      await _channel.invokeMethod('updateNotification', {
        'isPlaying': isPlaying,
      });
    } catch (e) {
      debugPrint('Failed to update notification state: $e');
    }
  }

  /// Update the notification with new song metadata.
  Future<void> updateNotification({
    required Song song,
    required bool isPlaying,
  }) async {
    try {
      await _channel.invokeMethod('updateNotification', {
        'title': song.title,
        'artist': song.artist,
        'albumArtPath': song.albumArt,
        'isPlaying': isPlaying,
      });
      _isNotificationVisible = true;
    } catch (e) {
      debugPrint('Failed to update notification: $e');
    }
  }

  /// Hide the notification and stop the foreground service.
  Future<void> hideNotification() async {
    try {
      await _channel.invokeMethod('hideNotification');
      _isNotificationVisible = false;
    } catch (e) {
      debugPrint('Failed to hide notification: $e');
    }
  }
}
