import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'lastfm_provider.dart';
import 'listenbrainz_provider.dart';
import '../models/playback_context.dart';
import '../models/shuffle_mode.dart';
import '../models/song.dart';
import '../services/player_service.dart';
import 'package:flick/core/utils/dev_log.dart';

// Re-export LoopMode from player_service
export '../services/player_service.dart' show LoopMode;
export '../models/shuffle_mode.dart' show ShuffleMode;
export '../models/playback_context.dart' show PlaybackContext, PlaybackSource;

/// State class representing the current player state.
@immutable
class PlayerState {
  final Song? currentSong;
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final Duration bufferedPosition;
  final bool isShuffle;
  final ShuffleMode shuffleMode;
  final LoopMode loopMode;
  final double playbackSpeed;
  final Duration? sleepTimerRemaining;
  final List<Song> queue;
  final List<Song> upNext;
  final int currentIndex;

  const PlayerState({
    this.currentSong,
    this.isPlaying = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.bufferedPosition = Duration.zero,
    this.isShuffle = false,
    this.shuffleMode = ShuffleMode.off,
    this.loopMode = LoopMode.all,
    this.playbackSpeed = 1.0,
    this.sleepTimerRemaining,
    this.queue = const [],
    this.upNext = const [],
    this.currentIndex = -1,
  });

  PlayerState copyWith({
    Song? currentSong,
    bool? isPlaying,
    Duration? position,
    Duration? duration,
    Duration? bufferedPosition,
    bool? isShuffle,
    ShuffleMode? shuffleMode,
    LoopMode? loopMode,
    double? playbackSpeed,
    Duration? sleepTimerRemaining,
    List<Song>? queue,
    List<Song>? upNext,
    int? currentIndex,
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
      shuffleMode: shuffleMode ?? this.shuffleMode,
      loopMode: loopMode ?? this.loopMode,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      sleepTimerRemaining: clearSleepTimer
          ? null
          : (sleepTimerRemaining ?? this.sleepTimerRemaining),
      queue: queue ?? this.queue,
      upNext: upNext ?? this.upNext,
      currentIndex: currentIndex ?? this.currentIndex,
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
  Song? _lastTrackedSong;
  int _lastTrackedPositionSeconds = 0;
  int _lastTrackedDurationSeconds = 0;

  /// Accumulated actual listen time for the current track (ignores seeks).
  int _accumulatedListenSeconds = 0;

  /// Expose accumulated listen seconds for lifecycle hooks (e.g. app pause).
  int get accumulatedListenSeconds => _accumulatedListenSeconds;

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
      shuffleMode: _service.shuffleModeNotifier.value,
      loopMode: _service.loopModeNotifier.value,
      playbackSpeed: _service.playbackSpeedNotifier.value,
      sleepTimerRemaining: _service.sleepTimerRemainingNotifier.value,
      queue: _service.queueNotifier.value,
      upNext: _service.upNextNotifier.value,
      currentIndex: _service.currentIndexNotifier.value,
    );

    DateTime lastPositionSync = DateTime.now();
    const positionThrottle = Duration(milliseconds: 250);

    // Listen to ValueNotifiers and update state (except position/bufferedPosition)
    void syncState() {
      final latestSong = _service.currentSongNotifier.value;
      final latestDurationSeconds = _service.durationNotifier.value.inSeconds;

      if (_lastTrackedSong != null && latestSong?.id != _lastTrackedSong!.id) {
        _handleTrackEnded(
          endedSong: _lastTrackedSong!,
          listenedSeconds: _accumulatedListenSeconds,
          trackDurationSeconds: _lastTrackedDurationSeconds,
        );
      }

      if (latestSong != null && latestSong.id != _lastTrackedSong?.id) {
        _handleTrackStarted(latestSong);
        _accumulatedListenSeconds = 0;
        _lastTrackedPositionSeconds = _service.positionNotifier.value.inSeconds;
      }

      final isSameTrack =
          latestSong != null && latestSong.id == _lastTrackedSong?.id;

      // Latch duration to highest value for the same track. During gapless
      // transitions the player may briefly reset duration to 0 before the
      // song notifier fires, which would wipe the stored value.
      if (!isSameTrack) {
        _lastTrackedDurationSeconds = latestDurationSeconds;
      } else if (latestDurationSeconds > _lastTrackedDurationSeconds) {
        _lastTrackedDurationSeconds = latestDurationSeconds;
      }

      _lastTrackedSong = latestSong;

      state = state.copyWith(
        currentSong: latestSong,
        isPlaying: _service.isPlayingNotifier.value,
        position: _service.positionNotifier.value,
        duration: _service.durationNotifier.value,
        bufferedPosition: _service.bufferedPositionNotifier.value,
        isShuffle: _service.isShuffleNotifier.value,
        shuffleMode: _service.shuffleModeNotifier.value,
        loopMode: _service.loopModeNotifier.value,
        playbackSpeed: _service.playbackSpeedNotifier.value,
        sleepTimerRemaining: _service.sleepTimerRemainingNotifier.value,
        queue: _service.queueNotifier.value,
        upNext: _service.upNextNotifier.value,
        currentIndex: _service.currentIndexNotifier.value,
        clearSong: _service.currentSongNotifier.value == null,
        clearSleepTimer: _service.sleepTimerRemainingNotifier.value == null,
      );
    }

    void syncPosition() {
      final latestPosition = _service.positionNotifier.value;
      final latestPositionSeconds = latestPosition.inSeconds;
      final latestSong = _service.currentSongNotifier.value;
      final latestDurationSeconds = _service.durationNotifier.value.inSeconds;

      final isSameTrack =
          latestSong != null && latestSong.id == _lastTrackedSong?.id;

      if (isSameTrack) {
        // Accumulate actual listen time: only count small position deltas
        // (≤ 3s) as real playback. Larger jumps indicate seeks.
        final delta = latestPositionSeconds - _lastTrackedPositionSeconds;
        if (delta > 0 && delta <= 3) {
          _accumulatedListenSeconds += delta;
        }

        final positionAdvanced =
            latestPositionSeconds > _lastTrackedPositionSeconds;
        if (positionAdvanced && !latestSong.isExternal) {
          unawaited(
            ref
                .read(lastFmScrobbleProvider.notifier)
                .onPlaybackProgress(
                  artist: latestSong.artist,
                  track: latestSong.title,
                  album: latestSong.album,
                  albumArtist: null,
                  listenedSeconds: _accumulatedListenSeconds,
                  trackDurationSeconds: latestDurationSeconds,
                ),
          );
        }
      }

      _lastTrackedPositionSeconds = latestPositionSeconds;

      final now = DateTime.now();
      if (now.difference(lastPositionSync) > positionThrottle) {
        lastPositionSync = now;
        state = state.copyWith(
          position: latestPosition,
          bufferedPosition: _service.bufferedPositionNotifier.value,
        );
      }
    }

    // Add listeners
    _service.currentSongNotifier.addListener(syncState);
    _service.isPlayingNotifier.addListener(syncState);
    _service.positionNotifier.addListener(syncPosition);
    _service.durationNotifier.addListener(syncState);
    _service.bufferedPositionNotifier.addListener(syncPosition);
    _service.isShuffleNotifier.addListener(syncState);
    _service.shuffleModeNotifier.addListener(syncState);
    _service.loopModeNotifier.addListener(syncState);
    _service.playbackSpeedNotifier.addListener(syncState);
    _service.sleepTimerRemainingNotifier.addListener(syncState);
    _service.queueNotifier.addListener(syncState);
    _service.upNextNotifier.addListener(syncState);
    _service.currentIndexNotifier.addListener(syncState);

    // Cleanup listeners when provider is disposed
    ref.onDispose(() {
      _service.currentSongNotifier.removeListener(syncState);
      _service.isPlayingNotifier.removeListener(syncState);
      _service.positionNotifier.removeListener(syncPosition);
      _service.durationNotifier.removeListener(syncState);
      _service.bufferedPositionNotifier.removeListener(syncPosition);
      _service.isShuffleNotifier.removeListener(syncState);
      _service.shuffleModeNotifier.removeListener(syncState);
      _service.loopModeNotifier.removeListener(syncState);
      _service.playbackSpeedNotifier.removeListener(syncState);
      _service.sleepTimerRemainingNotifier.removeListener(syncState);
      _service.queueNotifier.removeListener(syncState);
      _service.upNextNotifier.removeListener(syncState);
      _service.currentIndexNotifier.removeListener(syncState);
    });

    return initial;
  }

  void _handleTrackStarted(Song song) {
    if (song.isExternal) {
      return;
    }
    unawaited(
      ref
          .read(lastFmScrobbleProvider.notifier)
          .onTrackStarted(
            artist: song.artist,
            track: song.title,
            album: song.album,
            albumArtist: null,
            durationSeconds: song.duration.inSeconds,
          )
          .catchError((e) => devLog('[LastFm] onTrackStarted error: $e')),
    );
    unawaited(
      ref
          .read(listenBrainzScrobbleProvider.notifier)
          .onTrackStarted(
            artist: song.artist,
            track: song.title,
            album: song.album,
            albumArtist: null,
            durationSeconds: song.duration.inSeconds,
          )
          .catchError((e) => devLog('[ListenBrainz] onTrackStarted error: $e')),
    );
  }

  void _handleTrackEnded({
    required Song endedSong,
    required int listenedSeconds,
    required int trackDurationSeconds,
  }) {
    if (endedSong.isExternal) {
      return;
    }
    unawaited(
      ref
          .read(lastFmScrobbleProvider.notifier)
          .onTrackEnded(
            artist: endedSong.artist,
            track: endedSong.title,
            album: endedSong.album,
            albumArtist: null,
            listenedSeconds: listenedSeconds,
            trackDurationSeconds: trackDurationSeconds,
          )
          .catchError((e) => devLog('[LastFm] onTrackEnded error: $e')),
    );
    unawaited(
      ref
          .read(listenBrainzScrobbleProvider.notifier)
          .onTrackEnded(
            artist: endedSong.artist,
            track: endedSong.title,
            album: endedSong.album,
            albumArtist: null,
            listenedSeconds: listenedSeconds,
            trackDurationSeconds: trackDurationSeconds,
          )
          .catchError((e) => devLog('[ListenBrainz] onTrackEnded error: $e')),
    );
  }

  /// Play a song, optionally with a playlist context.
  Future<void> play(Song song, {List<Song>? playlist, PlaybackContext? context}) async {
    await _service.play(song, playlist: playlist, context: context);
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
  /// [allowRestart] true = button behavior (restart if >3s), false = swipe/slide (always previous track)
  Future<void> previous({bool allowRestart = true}) async {
    await _service.previous(allowRestart: allowRestart);
  }

  Future<void> previousBySwipe() async {
    await _service.previousBySwipe();
  }

  /// Toggle shuffle mode.
  Future<void> toggleShuffle() async {
    await _service.toggleShuffle();
  }

  Future<int> addToQueue(Song song) async {
    return _service.addToQueue(song);
  }

  Future<void> playFromQueueIndex(int index) async {
    await _service.playFromQueueIndex(index);
  }

  Future<void> playFromUpNextIndex(int index) async {
    await _service.playFromUpNextIndex(index);
  }

  Future<void> clearQueue() async {
    await _service.clearQueue();
  }

  Future<void> removeFromQueue(int index) async {
    await _service.removeFromQueue(index);
  }

  Future<void> moveQueueItem(int oldIndex, int newIndex) async {
    await _service.moveQueueItem(oldIndex, newIndex);
  }

  Future<void> moveQueueItemToNext(int index) async {
    await _service.moveQueueItemToNext(index);
  }

  Future<void> moveUpNextItem(int oldIndex, int newIndex) async {
    await _service.moveUpNextItem(oldIndex, newIndex);
  }

  Future<void> clearAllUpcoming() async {
    await _service.clearAllUpcoming();
  }

  Future<void> removeFromUpNext(int upNextIndex) async {
    await _service.removeFromUpNext(upNextIndex);
  }

  /// Toggle loop mode (quick cycle: off → all → one).
  void toggleLoopMode() {
    unawaited(_service.toggleLoopMode());
  }

  /// Set a specific loop mode.
  Future<void> setLoopMode(LoopMode mode) async {
    await _service.setLoopMode(mode);
  }

  /// Set a specific shuffle mode.
  Future<void> setShuffleMode(ShuffleMode mode) async {
    await _service.setShuffleMode(mode);
  }

  /// Set A-B repeat point A at current position.
  void setAbRepeatA() {
    _service.setAbRepeatA();
  }

  /// Set A-B repeat point B at current position.
  void setAbRepeatB() {
    _service.setAbRepeatB();
  }

  /// Clear A-B repeat.
  void clearAbRepeat() {
    _service.clearAbRepeat();
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

  /// Sync UI state with the actual engine playback state.
  void syncNow() {
    _service.syncNow();
  }
}

/// Main player state provider.
final playerProvider = NotifierProvider<PlayerNotifier, PlayerState>(
  PlayerNotifier.new,
);

// ============================================================================
// Convenience selectors for granular rebuilds
// ============================================================================

/// Current song selector.
///
/// Watches `playerProvider` without `.select` so in-place updates that don't
/// change `Song.id` (e.g. album-art rewrites via `syncAlbumArtPaths`) still
/// re-emit. `Song.==` is by id, so `.select((s) => s.currentSong)` would mask
/// those changes.
final currentSongProvider = Provider<Song?>((ref) {
  return ref.watch(playerProvider).currentSong;
});

/// Is playing selector.
final isPlayingProvider = Provider<bool>((ref) {
  return ref.watch(playerProvider.select((state) => state.isPlaying));
});

final queueProvider = Provider<List<Song>>((ref) {
  return ref.watch(playerProvider.select((state) => state.queue));
});

final upNextProvider = Provider<List<Song>>((ref) {
  return ref.watch(playerProvider.select((state) => state.upNext));
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

/// Shuffle mode selector (full enum).
final shuffleModeProvider = Provider<ShuffleMode>((ref) {
  return ref.watch(playerProvider.select((state) => state.shuffleMode));
});

/// Sleep timer remaining selector.
final sleepTimerRemainingProvider = Provider<Duration?>((ref) {
  return ref.watch(playerProvider.select((state) => state.sleepTimerRemaining));
});
