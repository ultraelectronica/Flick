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
    required VoidCallback onToggleShuffle,
    required VoidCallback onToggleFavorite,
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
        case 'toggleShuffle':
          onToggleShuffle();
          break;
        case 'toggleFavorite':
          onToggleFavorite();
          break;
      }
    });
  }

  /// Show or update the notification with song information.
  Future<void> showNotification({
    required Song song,
    required bool isPlaying,
    Duration? duration,
    Duration? position,
    bool isShuffle = false,
    bool isFavorite = false,
  }) async {
    try {
      await _channel.invokeMethod('showNotification', {
        'title': song.title,
        'artist': song.artist,
        'albumArtPath': song.albumArt,
        'isPlaying': isPlaying,
        'duration': duration?.inMilliseconds ?? 0,
        'position': position?.inMilliseconds ?? 0,
        'isShuffle': isShuffle,
        'isFavorite': isFavorite,
      });
      _isNotificationVisible = true;
    } catch (e) {
      debugPrint('Failed to show notification: $e');
    }
  }

  /// Update only the playback state (play/pause button) in the notification.
  Future<void> updatePlaybackState({
    required bool isPlaying,
    Duration? position,
  }) async {
    if (!_isNotificationVisible) return;

    try {
      final args = <String, dynamic>{'isPlaying': isPlaying};
      if (position != null) {
        args['position'] = position.inMilliseconds;
      }
      await _channel.invokeMethod('updateNotification', args);
    } catch (e) {
      debugPrint('Failed to update notification state: $e');
    }
  }

  /// Update the notification with new song metadata or state.
  Future<void> updateNotification({
    required Song song,
    required bool isPlaying,
    Duration? duration,
    Duration? position,
    bool? isShuffle,
    bool? isFavorite,
  }) async {
    try {
      final args = <String, dynamic>{
        'title': song.title,
        'artist': song.artist,
        'albumArtPath': song.albumArt,
        'isPlaying': isPlaying,
        'duration': duration?.inMilliseconds ?? 0,
        'position': position?.inMilliseconds ?? 0,
      };

      if (isShuffle != null) args['isShuffle'] = isShuffle;
      if (isFavorite != null) args['isFavorite'] = isFavorite;

      await _channel.invokeMethod('updateNotification', args);
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
