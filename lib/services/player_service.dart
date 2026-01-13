import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:flick/models/song.dart';
import 'package:flick/services/notification_service.dart';
import 'package:flick/services/last_played_service.dart';
import 'package:flick/services/favorites_service.dart';
import 'package:flick/services/rust_audio_service.dart';
import 'package:flick/data/repositories/recently_played_repository.dart';

/// Loop mode for playback
enum LoopMode { off, one, all }

/// Singleton service to manage global audio playback state.
///
/// Uses the Rust audio engine for high-performance playback with
/// gapless playback and crossfade support on desktop platforms.
/// Falls back to just_audio on Android.
class PlayerService {
  static final PlayerService _instance = PlayerService._internal();

  factory PlayerService() {
    return _instance;
  }

  PlayerService._internal() {
    _init();
  }

  // Rust audio engine (used on desktop)
  final RustAudioService _rustAudio = RustAudioService();

  // just_audio player (used as fallback on Android)
  final just_audio.AudioPlayer _justAudioPlayer = just_audio.AudioPlayer();

  // Whether we're using native Rust audio or just_audio fallback
  bool _useNativeAudio = false;

  final NotificationService _notificationService = NotificationService();
  final LastPlayedService _lastPlayedService = LastPlayedService();
  final FavoritesService _favoritesService = FavoritesService();
  final RecentlyPlayedRepository _recentlyPlayedRepository =
      RecentlyPlayedRepository();

  // Timer to periodically save position
  Timer? _positionSaveTimer;

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

  // Playback Speed
  final ValueNotifier<double> playbackSpeedNotifier = ValueNotifier(1.0);

  // Crossfade settings
  final ValueNotifier<bool> crossfadeEnabledNotifier = ValueNotifier(false);
  final ValueNotifier<double> crossfadeDurationNotifier = ValueNotifier(3.0);

  // Sleep Timer
  final ValueNotifier<Duration?> sleepTimerRemainingNotifier = ValueNotifier(
    null,
  );
  Timer? _sleepTimer;
  Timer? _sleepTimerCountdown;

  // Playlist Management
  final List<Song> _playlist = [];
  final List<Song> _originalPlaylist = []; // For shuffle restore
  int _currentIndex = -1;

  /// Whether native (Rust) audio engine is being used.
  bool get isUsingNativeAudio => _useNativeAudio;

  void _init() {
    // Initialize notification service with callbacks
    _notificationService.init(
      onTogglePlayPause: togglePlayPause,
      onNext: next,
      onPrevious: previous,
      onStop: _stopPlayback,
      onSeek: seek,
      onToggleShuffle: toggleShuffle,
      onToggleFavorite: _toggleFavoriteFromNotification,
    );
  }

  /// Initialize the audio engine.
  /// Attempts to use native Rust audio, falls back to just_audio if unavailable.
  Future<void> initRustAudio() async {
    bool nativeInitialized = false;

    try {
      nativeInitialized = await _rustAudio.init();
    } catch (e) {
      debugPrint('Rust audio init failed: $e');
      nativeInitialized = false;
    }

    if (nativeInitialized) {
      _useNativeAudio = true;
      debugPrint('Using native Rust audio engine');

      // Set up Rust audio callbacks
      _rustAudio.onTrackEnded = _onTrackEnded;
      _rustAudio.onCrossfadeStarted = (from, to) {
        debugPrint('Crossfade started: $from -> $to');
      };
      _rustAudio.onError = (message) {
        debugPrint('Audio error: $message');
      };

      // Listen to Rust audio state changes
      _rustAudio.stateNotifier.addListener(_onRustStateChanged);
      _rustAudio.positionNotifier.addListener(_onRustPositionChanged);
      _rustAudio.durationNotifier.addListener(_onRustDurationChanged);
      _rustAudio.bufferLevelNotifier.addListener(_onRustBufferChanged);

      // Sync crossfade settings
      await _rustAudio.setCrossfade(
        enabled: crossfadeEnabledNotifier.value,
        durationSecs: crossfadeDurationNotifier.value,
      );
    } else {
      _useNativeAudio = false;
      debugPrint('Using just_audio fallback');

      // Set up just_audio listeners
      _setupJustAudioListeners();
    }
  }

  void _setupJustAudioListeners() {
    _justAudioPlayer.playerStateStream.listen((state) {
      final wasPlaying = isPlayingNotifier.value;
      isPlayingNotifier.value = state.playing;

      if (wasPlaying != state.playing && currentSongNotifier.value != null) {
        _notificationService.updatePlaybackState(isPlaying: state.playing);
      }

      if (state.processingState == just_audio.ProcessingState.completed) {
        _onSongFinished();
      }
    });

    _justAudioPlayer.positionStream.listen((pos) {
      positionNotifier.value = pos;
    });

    _justAudioPlayer.bufferedPositionStream.listen((pos) {
      bufferedPositionNotifier.value = pos;
    });

    _justAudioPlayer.durationStream.listen((dur) {
      if (dur != null) {
        durationNotifier.value = dur;
        if (currentSongNotifier.value != null && isPlayingNotifier.value) {
          _updateNotificationState();
        }
      }
    });
  }

  void _onRustStateChanged() {
    final state = _rustAudio.stateNotifier.value;
    final wasPlaying = isPlayingNotifier.value;

    isPlayingNotifier.value =
        state == RustPlaybackState.playing ||
        state == RustPlaybackState.crossfading;

    if (wasPlaying != isPlayingNotifier.value &&
        currentSongNotifier.value != null) {
      _notificationService.updatePlaybackState(
        isPlaying: isPlayingNotifier.value,
      );
    }
  }

  void _onRustPositionChanged() {
    positionNotifier.value = _rustAudio.positionNotifier.value;
  }

  void _onRustDurationChanged() {
    final dur = _rustAudio.durationNotifier.value;
    if (dur != Duration.zero) {
      durationNotifier.value = dur;
      if (currentSongNotifier.value != null && isPlayingNotifier.value) {
        _updateNotificationState();
      }
    }
  }

  void _onRustBufferChanged() {
    final bufferLevel = _rustAudio.bufferLevelNotifier.value;
    final duration = durationNotifier.value;
    bufferedPositionNotifier.value = Duration(
      milliseconds: (duration.inMilliseconds * bufferLevel).round(),
    );
  }

  void _onTrackEnded(String path) {
    _onSongFinished();
  }

  Future<void> _toggleFavoriteFromNotification() async {
    final song = currentSongNotifier.value;
    if (song != null) {
      await _favoritesService.toggleFavorite(song.id);
      _updateNotificationState();
    }
  }

  Future<void> _updateNotificationState() async {
    final song = currentSongNotifier.value;
    if (song == null) return;

    final isFav = await _favoritesService.isFavorite(song.id);

    await _notificationService.updateNotification(
      song: song,
      isPlaying: isPlayingNotifier.value,
      duration: durationNotifier.value,
      position: positionNotifier.value,
      isShuffle: isShuffleNotifier.value,
      isFavorite: isFav,
    );
  }

  Future<void> _onSongFinished() async {
    if (loopModeNotifier.value == LoopMode.one) {
      if (currentSongNotifier.value != null) {
        await play(currentSongNotifier.value!);
      }
    } else {
      await next();
    }
  }

  void _stopPlayback() async {
    await _savePosition();
    _positionSaveTimer?.cancel();

    if (_useNativeAudio) {
      await _rustAudio.stop();
    } else {
      await _justAudioPlayer.pause();
      await _justAudioPlayer.seek(Duration.zero);
    }

    cancelSleepTimer();
    _notificationService.hideNotification();
  }

  /// Play a specific song.
  Future<void> play(Song song, {List<Song>? playlist}) async {
    try {
      _positionSaveTimer?.cancel();

      if (playlist != null) {
        _playlist.clear();
        _playlist.addAll(playlist);
        _originalPlaylist.clear();
        _originalPlaylist.addAll(playlist);
        _currentIndex = _playlist.indexOf(song);
      } else {
        if (!_playlist.contains(song)) {
          _playlist.clear();
          _playlist.add(song);
          _originalPlaylist.clear();
          _originalPlaylist.add(song);
          _currentIndex = 0;
        } else {
          _currentIndex = _playlist.indexOf(song);
        }
      }

      currentSongNotifier.value = song;
      _recentlyPlayedRepository.recordPlay(song.id);

      positionNotifier.value = Duration.zero;
      durationNotifier.value = Duration.zero;

      if (song.filePath != null) {
        final isFav = await _favoritesService.isFavorite(song.id);

        await _notificationService.showNotification(
          song: song,
          isPlaying: true,
          duration: song.duration,
          position: Duration.zero,
          isShuffle: isShuffleNotifier.value,
          isFavorite: isFav,
        );

        if (_useNativeAudio) {
          await _rustAudio.play(song.filePath!);
          await _queueNextTrackForGapless();
        } else {
          await _justAudioPlayer.setAudioSource(
            just_audio.AudioSource.uri(Uri.parse(song.filePath!)),
          );
          await _justAudioPlayer.setSpeed(playbackSpeedNotifier.value);
          await _justAudioPlayer.play();
        }

        _positionSaveTimer = Timer.periodic(
          const Duration(seconds: 5),
          (_) => _savePosition(),
        );
      }
    } catch (e) {
      debugPrint("Error playing song: $e");
    }
  }

  Future<void> _queueNextTrackForGapless() async {
    if (!_useNativeAudio) return;
    if (_playlist.isEmpty || _currentIndex < 0) return;

    Song? nextSong;

    if (_currentIndex < _playlist.length - 1) {
      nextSong = _playlist[_currentIndex + 1];
    } else if (loopModeNotifier.value == LoopMode.all) {
      nextSong = _playlist[0];
    }

    if (nextSong?.filePath != null) {
      await _rustAudio.queueNext(nextSong!.filePath!);
      debugPrint('Queued next track for gapless: ${nextSong.title}');
    }
  }

  Future<void> _savePosition() async {
    final song = currentSongNotifier.value;
    if (song != null) {
      await _lastPlayedService.saveLastPlayed(song.id, positionNotifier.value);
    }
  }

  Future<void> restoreLastPlayed() async {
    final lastPlayed = await _lastPlayedService.getLastPlayed();
    if (lastPlayed != null) {
      currentSongNotifier.value = lastPlayed.song;
      _playlist.clear();
      _playlist.add(lastPlayed.song);
      _originalPlaylist.clear();
      _originalPlaylist.add(lastPlayed.song);
      _currentIndex = 0;

      if (lastPlayed.song.filePath != null) {
        try {
          positionNotifier.value = lastPlayed.position;
          durationNotifier.value = lastPlayed.song.duration;

          final isFav = await _favoritesService.isFavorite(lastPlayed.song.id);
          await _notificationService.showNotification(
            song: lastPlayed.song,
            isPlaying: false,
            position: lastPlayed.position,
            isShuffle: isShuffleNotifier.value,
            isFavorite: isFav,
          );
        } catch (e) {
          debugPrint("Error restoring last played: $e");
        }
      }
    }
  }

  Future<void> pause() async {
    // Immediately update the playing state for responsive UI
    isPlayingNotifier.value = false;

    if (_useNativeAudio) {
      await _rustAudio.pause();
    } else {
      await _justAudioPlayer.pause();
    }
    _updateNotificationState();
  }

  Future<void> resume() async {
    final song = currentSongNotifier.value;

    // Immediately update the playing state for responsive UI
    isPlayingNotifier.value = true;

    if (_useNativeAudio) {
      if (song?.filePath != null &&
          (_rustAudio.state == RustPlaybackState.idle ||
              _rustAudio.state == RustPlaybackState.stopped)) {
        await _rustAudio.play(song!.filePath!);
        if (positionNotifier.value != Duration.zero) {
          await _rustAudio.seek(positionNotifier.value);
        }
      } else {
        await _rustAudio.resume();
      }
    } else {
      if (song?.filePath != null &&
          _justAudioPlayer.processingState == just_audio.ProcessingState.idle) {
        await _justAudioPlayer.setAudioSource(
          just_audio.AudioSource.uri(Uri.parse(song!.filePath!)),
        );
        await _justAudioPlayer.seek(positionNotifier.value);
      }
      await _justAudioPlayer.play();
    }
    _updateNotificationState();
  }

  Future<void> togglePlayPause() async {
    if (isPlayingNotifier.value) {
      await pause();
    } else {
      await resume();
    }
  }

  Future<void> seek(Duration position) async {
    if (_useNativeAudio) {
      await _rustAudio.seek(position);
    } else {
      await _justAudioPlayer.seek(position);
    }
    _updateNotificationState();
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
      await pause();
      await seek(Duration.zero);
    }
  }

  Future<void> previous() async {
    if (_playlist.isEmpty) return;

    if (positionNotifier.value.inSeconds > 3) {
      await seek(Duration.zero);
    } else {
      if (_currentIndex > 0) {
        _currentIndex--;
        await play(_playlist[_currentIndex]);
      } else {
        await seek(Duration.zero);
      }
    }
  }

  // ==================== Crossfade Settings ====================

  Future<void> setCrossfadeEnabled(bool enabled) async {
    crossfadeEnabledNotifier.value = enabled;
    if (_useNativeAudio) {
      await _rustAudio.setCrossfade(
        enabled: enabled,
        durationSecs: crossfadeDurationNotifier.value,
      );
    }
    // Note: just_audio doesn't support crossfade natively
  }

  Future<void> setCrossfadeDuration(double durationSecs) async {
    crossfadeDurationNotifier.value = durationSecs.clamp(0.5, 12.0);
    if (_useNativeAudio && crossfadeEnabledNotifier.value) {
      await _rustAudio.setCrossfade(
        enabled: true,
        durationSecs: crossfadeDurationNotifier.value,
      );
    }
  }

  // ==================== Shuffle/Loop Toggles ====================

  void toggleShuffle() {
    final enable = !isShuffleNotifier.value;
    isShuffleNotifier.value = enable;

    if (enable) {
      final current = currentSongNotifier.value;
      if (current != null) {
        _playlist.shuffle();
        _currentIndex = _playlist.indexOf(current);
      } else {
        _playlist.shuffle();
      }
    } else {
      final current = currentSongNotifier.value;
      _playlist.clear();
      _playlist.addAll(_originalPlaylist);
      if (current != null) {
        _currentIndex = _playlist.indexOf(current);
      }
    }

    if (_useNativeAudio) {
      _queueNextTrackForGapless();
    }
    _updateNotificationState();
  }

  void toggleLoopMode() {
    final modes = LoopMode.values;
    final nextIndex = (loopModeNotifier.value.index + 1) % modes.length;
    loopModeNotifier.value = modes[nextIndex];

    if (_useNativeAudio) {
      _queueNextTrackForGapless();
    }
  }

  // ==================== Volume ====================

  Future<void> setVolume(double volume) async {
    if (_useNativeAudio) {
      await _rustAudio.setVolume(volume);
    } else {
      await _justAudioPlayer.setVolume(volume);
    }
  }

  // ==================== Playback Speed ====================

  Future<void> setPlaybackSpeed(double speed) async {
    final clampedSpeed = speed.clamp(0.5, 2.0);
    playbackSpeedNotifier.value = clampedSpeed;

    if (_useNativeAudio) {
      await _rustAudio.setPlaybackSpeed(clampedSpeed);
    } else {
      await _justAudioPlayer.setSpeed(clampedSpeed);
    }
  }

  Future<void> cyclePlaybackSpeed() async {
    const speeds = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    final currentIndex = speeds.indexOf(playbackSpeedNotifier.value);
    final nextIndex = (currentIndex + 1) % speeds.length;
    await setPlaybackSpeed(speeds[nextIndex]);
  }

  // ==================== Sleep Timer ====================

  void setSleepTimer(Duration duration) {
    cancelSleepTimer();

    sleepTimerRemainingNotifier.value = duration;

    _sleepTimer = Timer(duration, () {
      _stopPlayback();
      sleepTimerRemainingNotifier.value = null;
    });

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

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerCountdown?.cancel();
    _sleepTimerCountdown = null;
    sleepTimerRemainingNotifier.value = null;
  }

  bool get isSleepTimerActive => sleepTimerRemainingNotifier.value != null;

  void dispose() {
    _positionSaveTimer?.cancel();
    cancelSleepTimer();
    _notificationService.hideNotification();

    if (_useNativeAudio) {
      _rustAudio.shutdown();
      _rustAudio.dispose();
    } else {
      _justAudioPlayer.dispose();
    }

    currentSongNotifier.dispose();
    isPlayingNotifier.dispose();
    positionNotifier.dispose();
    durationNotifier.dispose();
    bufferedPositionNotifier.dispose();
    playbackSpeedNotifier.dispose();
    crossfadeEnabledNotifier.dispose();
    crossfadeDurationNotifier.dispose();
    sleepTimerRemainingNotifier.dispose();
  }
}
