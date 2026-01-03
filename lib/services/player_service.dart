import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/notification_service.dart';

/// Singleton service to manage global audio playback state.
class PlayerService {
  static final PlayerService _instance = PlayerService._internal();

  factory PlayerService() {
    return _instance;
  }

  PlayerService._internal() {
    _init();
  }

  final AudioPlayer _player = AudioPlayer();
  final NotificationService _notificationService = NotificationService();

  // State Notifiers
  final ValueNotifier<Song?> currentSongNotifier = ValueNotifier(null);
  final ValueNotifier<bool> isPlayingNotifier = ValueNotifier(false);
  final ValueNotifier<Duration> positionNotifier = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> durationNotifier = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> bufferedPositionNotifier = ValueNotifier(
    Duration.zero,
  );

  // Playback Mode State
  final ValueNotifier<bool> isShuffleNotifier = ValueNotifier(false);
  final ValueNotifier<LoopMode> loopModeNotifier = ValueNotifier(LoopMode.off);

  // Playback Speed (0.5x - 2.0x)
  final ValueNotifier<double> playbackSpeedNotifier = ValueNotifier(1.0);

  // Sleep Timer
  final ValueNotifier<Duration?> sleepTimerRemainingNotifier = ValueNotifier(
    null,
  );
  Timer? _sleepTimer;
  Timer? _sleepTimerCountdown;

  // Playlist Management
  final List<Song> _playlist = [];
  int _currentIndex = -1;

  void _init() {
    // Initialize notification service with callbacks
    _notificationService.init(
      onTogglePlayPause: togglePlayPause,
      onNext: next,
      onPrevious: previous,
      onStop: _stopPlayback,
      onSeek: seek,
    );

    // Listen to player state
    _player.playerStateStream.listen((state) {
      final wasPlaying = isPlayingNotifier.value;
      isPlayingNotifier.value = state.playing;

      // Update notification on play/pause state change
      if (wasPlaying != state.playing && currentSongNotifier.value != null) {
        _notificationService.updatePlaybackState(isPlaying: state.playing);
      }

      if (state.processingState == ProcessingState.completed) {
        _onSongFinished();
      }
    });

    // Listen to position updates
    _player.positionStream.listen((pos) {
      positionNotifier.value = pos;
    });

    // Listen to buffered position
    _player.bufferedPositionStream.listen((pos) {
      bufferedPositionNotifier.value = pos;
    });

    // Listen to duration changes
    _player.durationStream.listen((dur) {
      if (dur != null) {
        durationNotifier.value = dur;
      }
    });
  }

  Future<void> _onSongFinished() async {
    // Auto-advance logic
    if (loopModeNotifier.value == LoopMode.one) {
      if (currentSongNotifier.value != null) {
        await play(currentSongNotifier.value!);
      }
    } else {
      await next();
    }
  }

  void _stopPlayback() async {
    await pause();
    await seek(Duration.zero);
    cancelSleepTimer();
    _notificationService.hideNotification();
  }

  /// Play a specific song.
  /// If [playlist] is provided, it replaces the current queue.
  Future<void> play(Song song, {List<Song>? playlist}) async {
    try {
      if (playlist != null) {
        _playlist.clear();
        _playlist.addAll(playlist);
        _currentIndex = _playlist.indexOf(song);
      } else {
        // If playing a standalone song not in current playlist, add it or just play it?
        // For simplicity, let's treat it as a single song playlist if queue is empty/desync.
        if (!_playlist.contains(song)) {
          _playlist.clear();
          _playlist.add(song);
          _currentIndex = 0;
        } else {
          _currentIndex = _playlist.indexOf(song);
        }
      }

      currentSongNotifier.value = song;

      // Reset duration/position for UI responsiveness
      positionNotifier.value = Duration.zero;
      durationNotifier.value = Duration.zero;

      if (song.filePath != null) {
        await _player.setAudioSource(
          AudioSource.uri(Uri.parse(song.filePath!)),
        );

        // Apply current playback speed
        await _player.setSpeed(playbackSpeedNotifier.value);

        await _player.play();

        // Show notification for background playback
        await _notificationService.showNotification(
          song: song,
          isPlaying: true,
        );
      }
    } catch (e) {
      debugPrint("Error playing song: $e");
    }
  }

  Future<void> pause() async {
    await _player.pause();
  }

  Future<void> resume() async {
    await _player.play();
  }

  Future<void> togglePlayPause() async {
    if (isPlayingNotifier.value) {
      await pause();
    } else {
      await resume();
    }
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  Future<void> next() async {
    if (_playlist.isEmpty) return;

    if (_currentIndex < _playlist.length - 1) {
      _currentIndex++;
      await play(_playlist[_currentIndex]);
    } else if (loopModeNotifier.value == LoopMode.all) {
      _currentIndex = 0;
      await play(_playlist[_currentIndex]);
    } else {
      // End of playlist, stop or stay?
      // Let's stop
      await pause();
      await seek(Duration.zero);
    }
  }

  Future<void> previous() async {
    if (_playlist.isEmpty) return;

    // If more than 3 seconds in, restart song
    if (positionNotifier.value.inSeconds > 3) {
      await seek(Duration.zero);
    } else {
      if (_currentIndex > 0) {
        _currentIndex--;
        await play(_playlist[_currentIndex]);
      } else {
        // Wrap around if desired, or just restart first song
        await seek(Duration.zero);
      }
    }
  }

  // Shuffle/Loop Toggles
  void toggleShuffle() {
    final enable = !isShuffleNotifier.value;
    isShuffleNotifier.value = enable;

    if (enable) {
      // Enable shuffle: shuffle the current playlist (except current song stays first ideally, or just shuffle all)
      // For a proper shuffle, we should keep the current song playing.
      // A simple approach:
      final current = currentSongNotifier.value;
      if (current != null) {
        // Remove current, shuffle rest, put current back at 0?
        // Or just shuffle mostly.
        // Let's just shuffle the whole thing for now to keep it simple, finding new index.
        _playlist.shuffle();
        _currentIndex = _playlist.indexOf(current);
      } else {
        _playlist.shuffle();
      }
    } else {
      // Disable shuffle: Restore original order?
      // We didn't save original order in this simple implementation.
      // Enhancing this would require storing _originalPlaylist.
      // Let's sort by title as a fallback or just leave it as is (randomized order becomes new order).
      // User might expect it to revert.
      _playlist.sort((a, b) => a.title.compareTo(b.title));
      final current = currentSongNotifier.value;
      if (current != null) {
        _currentIndex = _playlist.indexOf(current);
      }
    }
  }

  void toggleLoopMode() {
    final modes = LoopMode.values;
    final nextIndex = (loopModeNotifier.value.index + 1) % modes.length;
    loopModeNotifier.value = modes[nextIndex];
  }

  // ==================== Playback Speed ====================

  /// Set playback speed (0.5 - 2.0)
  Future<void> setPlaybackSpeed(double speed) async {
    final clampedSpeed = speed.clamp(0.5, 2.0);
    playbackSpeedNotifier.value = clampedSpeed;
    await _player.setSpeed(clampedSpeed);
  }

  /// Cycle through common playback speeds
  Future<void> cyclePlaybackSpeed() async {
    const speeds = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    final currentIndex = speeds.indexOf(playbackSpeedNotifier.value);
    final nextIndex = (currentIndex + 1) % speeds.length;
    await setPlaybackSpeed(speeds[nextIndex]);
  }

  // ==================== Sleep Timer ====================

  /// Set a sleep timer to stop playback after [duration].
  void setSleepTimer(Duration duration) {
    cancelSleepTimer();

    sleepTimerRemainingNotifier.value = duration;

    // Main timer to stop playback
    _sleepTimer = Timer(duration, () {
      _stopPlayback();
      sleepTimerRemainingNotifier.value = null;
    });

    // Countdown timer to update remaining time every second
    _sleepTimerCountdown = Timer.periodic(const Duration(seconds: 1), (timer) {
      final remaining = sleepTimerRemainingNotifier.value;
      if (remaining != null && remaining.inSeconds > 0) {
        sleepTimerRemainingNotifier.value =
            remaining - const Duration(seconds: 1);
      } else {
        timer.cancel();
      }
    });
  }

  /// Cancel any active sleep timer.
  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerCountdown?.cancel();
    _sleepTimerCountdown = null;
    sleepTimerRemainingNotifier.value = null;
  }

  /// Check if sleep timer is active.
  bool get isSleepTimerActive => sleepTimerRemainingNotifier.value != null;

  void dispose() {
    cancelSleepTimer();
    _notificationService.hideNotification();
    _player.dispose();
    currentSongNotifier.dispose();
    isPlayingNotifier.dispose();
    positionNotifier.dispose();
    durationNotifier.dispose();
    bufferedPositionNotifier.dispose();
    playbackSpeedNotifier.dispose();
    sleepTimerRemainingNotifier.dispose();
  }
}
