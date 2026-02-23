import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/song.dart';
import '../services/player_service.dart';

// Re-export LoopMode from player_service
export '../services/player_service.dart' show LoopMode;

/// State class representing the current player state.
@immutable
class PlayerState {
  final Song? currentSong;
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final Duration bufferedPosition;
  final bool isShuffle;
  final LoopMode loopMode;
  final double playbackSpeed;
  final Duration? sleepTimerRemaining;

  const PlayerState({
    this.currentSong,
    this.isPlaying = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.bufferedPosition = Duration.zero,
    this.isShuffle = false,
    this.loopMode = LoopMode.off,
    this.playbackSpeed = 1.0,
    this.sleepTimerRemaining,
  });

  PlayerState copyWith({
    Song? currentSong,
    bool? isPlaying,
    Duration? position,
    Duration? duration,
    Duration? bufferedPosition,
    bool? isShuffle,
    LoopMode? loopMode,
    double? playbackSpeed,
    Duration? sleepTimerRemaining,
    bool clearSong = false,
    bool clearSleepTimer = false,
  }) {
    return PlayerState(
      currentSong: clearSong ? null : (currentSong ?? this.currentSong),
      isPlaying: isPlaying ?? this.isPlaying,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      bufferedPosition: bufferedPosition ?? this.bufferedPosition,
      isShuffle: isShuffle ?? this.isShuffle,
      loopMode: loopMode ?? this.loopMode,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      sleepTimerRemaining: clearSleepTimer
          ? null
          : (sleepTimerRemaining ?? this.sleepTimerRemaining),
    );
  }

  /// Progress as a value between 0.0 and 1.0.
  double get progress {
    if (duration.inMilliseconds == 0) return 0.0;
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  /// Whether there is a song loaded.
  bool get hasSong => currentSong != null;
}

/// Provider for the PlayerService singleton.
/// This keeps the service alive for the app lifetime.
final playerServiceProvider = Provider<PlayerService>((ref) {
  return PlayerService();
});

/// Notifier that bridges PlayerService ValueNotifiers to Riverpod state.
class PlayerNotifier extends Notifier<PlayerState> {
  late PlayerService _service;

  @override
  PlayerState build() {
    _service = ref.watch(playerServiceProvider);

    // Sync initial state from service
    final initial = PlayerState(
      currentSong: _service.currentSongNotifier.value,
      isPlaying: _service.isPlayingNotifier.value,
      position: _service.positionNotifier.value,
      duration: _service.durationNotifier.value,
      bufferedPosition: _service.bufferedPositionNotifier.value,
      isShuffle: _service.isShuffleNotifier.value,
      loopMode: _service.loopModeNotifier.value,
      playbackSpeed: _service.playbackSpeedNotifier.value,
      sleepTimerRemaining: _service.sleepTimerRemainingNotifier.value,
    );

    // Listen to ValueNotifiers and update state
    void syncState() {
      state = state.copyWith(
        currentSong: _service.currentSongNotifier.value,
        isPlaying: _service.isPlayingNotifier.value,
        position: _service.positionNotifier.value,
        duration: _service.durationNotifier.value,
        bufferedPosition: _service.bufferedPositionNotifier.value,
        isShuffle: _service.isShuffleNotifier.value,
        loopMode: _service.loopModeNotifier.value,
        playbackSpeed: _service.playbackSpeedNotifier.value,
        sleepTimerRemaining: _service.sleepTimerRemainingNotifier.value,
        clearSong: _service.currentSongNotifier.value == null,
        clearSleepTimer: _service.sleepTimerRemainingNotifier.value == null,
      );
    }

    // Add listeners
    _service.currentSongNotifier.addListener(syncState);
    _service.isPlayingNotifier.addListener(syncState);
    _service.positionNotifier.addListener(syncState);
    _service.durationNotifier.addListener(syncState);
    _service.bufferedPositionNotifier.addListener(syncState);
    _service.isShuffleNotifier.addListener(syncState);
    _service.loopModeNotifier.addListener(syncState);
    _service.playbackSpeedNotifier.addListener(syncState);
    _service.sleepTimerRemainingNotifier.addListener(syncState);

    // Cleanup listeners when provider is disposed
    ref.onDispose(() {
      _service.currentSongNotifier.removeListener(syncState);
      _service.isPlayingNotifier.removeListener(syncState);
      _service.positionNotifier.removeListener(syncState);
      _service.durationNotifier.removeListener(syncState);
      _service.bufferedPositionNotifier.removeListener(syncState);
      _service.isShuffleNotifier.removeListener(syncState);
      _service.loopModeNotifier.removeListener(syncState);
      _service.playbackSpeedNotifier.removeListener(syncState);
      _service.sleepTimerRemainingNotifier.removeListener(syncState);
    });

    return initial;
  }

  /// Play a song, optionally with a playlist context.
  Future<void> play(Song song, {List<Song>? playlist}) async {
    await _service.play(song, playlist: playlist);
  }

  /// Toggle play/pause.
  Future<void> togglePlayPause() async {
    await _service.togglePlayPause();
  }

  /// Pause playback.
  Future<void> pause() async {
    await _service.pause();
  }

  /// Resume playback.
  Future<void> resume() async {
    await _service.resume();
  }

  /// Seek to a position.
  Future<void> seek(Duration position) async {
    await _service.seek(position);
  }

  /// Skip to next song.
  Future<void> next() async {
    await _service.next();
  }

  /// Skip to previous song.
  Future<void> previous() async {
    await _service.previous();
  }

  /// Toggle shuffle mode.
  void toggleShuffle() {
    _service.toggleShuffle();
  }

  /// Toggle loop mode.
  void toggleLoopMode() {
    _service.toggleLoopMode();
  }

  /// Set playback speed.
  Future<void> setPlaybackSpeed(double speed) async {
    await _service.setPlaybackSpeed(speed);
  }

  /// Cycle through playback speeds.
  Future<void> cyclePlaybackSpeed() async {
    await _service.cyclePlaybackSpeed();
  }

  /// Set a sleep timer.
  void setSleepTimer(Duration duration) {
    _service.setSleepTimer(duration);
  }

  /// Cancel the sleep timer.
  void cancelSleepTimer() {
    _service.cancelSleepTimer();
  }

  /// Set volume (0.0 to 1.0).
  Future<void> setVolume(double volume) async {
    await _service.setVolume(volume);
  }
}

/// Main player state provider.
final playerProvider = NotifierProvider<PlayerNotifier, PlayerState>(
  PlayerNotifier.new,
);

// ============================================================================
// Convenience selectors for granular rebuilds
// ============================================================================

/// Current song selector - only rebuilds when the song changes.
final currentSongProvider = Provider<Song?>((ref) {
  return ref.watch(playerProvider.select((state) => state.currentSong));
});

/// Is playing selector.
final isPlayingProvider = Provider<bool>((ref) {
  return ref.watch(playerProvider.select((state) => state.isPlaying));
});

/// Position selector - updates frequently during playback.
final positionProvider = Provider<Duration>((ref) {
  return ref.watch(playerProvider.select((state) => state.position));
});

/// Duration selector.
final durationProvider = Provider<Duration>((ref) {
  return ref.watch(playerProvider.select((state) => state.duration));
});

/// Progress selector (0.0 to 1.0).
final progressProvider = Provider<double>((ref) {
  return ref.watch(playerProvider.select((state) => state.progress));
});

/// Shuffle mode selector.
final isShuffleProvider = Provider<bool>((ref) {
  return ref.watch(playerProvider.select((state) => state.isShuffle));
});

/// Loop mode selector.
final loopModeProvider = Provider<LoopMode>((ref) {
  return ref.watch(playerProvider.select((state) => state.loopMode));
});

/// Playback speed selector.
final playbackSpeedProvider = Provider<double>((ref) {
  return ref.watch(playerProvider.select((state) => state.playbackSpeed));
});

/// Sleep timer remaining selector.
final sleepTimerRemainingProvider = Provider<Duration?>((ref) {
  return ref.watch(playerProvider.select((state) => state.sleepTimerRemaining));
});
