import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:flick/models/song.dart';
import 'package:flick/services/notification_service.dart';
import 'package:flick/services/last_played_service.dart';
import 'package:flick/services/favorites_service.dart';
import 'package:flick/data/repositories/recently_played_repository.dart';

/// Loop mode for playback
enum LoopMode { off, one, all }

/// Singleton service to manage global audio playback state.
///
/// Uses just_audio for playback with gapless playback support.
class PlayerService {
  static final PlayerService _instance = PlayerService._internal();

  factory PlayerService() {
    return _instance;
  }

  PlayerService._internal() {
    _init();
  }

  // just_audio player with gapless playback support
  final just_audio.AudioPlayer _justAudioPlayer = just_audio.AudioPlayer();

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
  /// Sets up just_audio with gapless playback support.
  Future<void> initAudio() async {
    debugPrint('Initializing just_audio with gapless playback support');

    // Set up just_audio listeners
    _setupJustAudioListeners();

    // Set initial loop mode
    await _updateLoopMode();
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

    // Listen to sequence state changes for gapless transitions
    _justAudioPlayer.sequenceStateStream.listen((sequenceState) {
      if (sequenceState.currentIndex != null) {
        final newIndex = sequenceState.currentIndex!;
        if (newIndex != _currentIndex && newIndex < _playlist.length) {
          _currentIndex = newIndex;
          final newSong = _playlist[newIndex];
          if (newSong != currentSongNotifier.value) {
            debugPrint(
              'Gapless transition: ${currentSongNotifier.value?.title} -> ${newSong.title}',
            );
            currentSongNotifier.value = newSong;
            _recentlyPlayedRepository.recordPlay(newSong.id);
            positionNotifier.value = Duration.zero;
            _updateNotificationState();
          }
        }
      }
    });
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
    debugPrint(
      '_onSongFinished: loopMode=${loopModeNotifier.value}, currentIndex=$_currentIndex, playlistLength=${_playlist.length}',
    );
    if (loopModeNotifier.value == LoopMode.one) {
      if (currentSongNotifier.value != null) {
        debugPrint('_onSongFinished: LoopMode.one, replaying current song');
        await play(currentSongNotifier.value!);
      }
    } else {
      debugPrint('_onSongFinished: Calling next()');
      await next();
    }
  }

  void _stopPlayback() async {
    await _savePosition();
    _positionSaveTimer?.cancel();

    await _justAudioPlayer.pause();
    await _justAudioPlayer.seek(Duration.zero);

    cancelSleepTimer();
    _notificationService.hideNotification();
  }

  /// Build audio sources for the playlist (gapless playback).
  List<just_audio.AudioSource> _buildAudioSources() {
    return _playlist.map((song) {
      if (song.filePath == null) {
        return just_audio.AudioSource.uri(Uri.parse(''));
      }
      return just_audio.AudioSource.uri(Uri.parse(song.filePath!));
    }).toList();
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

        // Build audio sources for gapless playback
        final sources = _buildAudioSources();

        await _justAudioPlayer.setAudioSources(
          sources,
          initialIndex: _currentIndex,
          preload: true, // Enable gapless playback by preloading next track
        );
        await _justAudioPlayer.setSpeed(playbackSpeedNotifier.value);
        await _updateLoopMode();
        await _justAudioPlayer.play();

        _positionSaveTimer = Timer.periodic(
          const Duration(seconds: 5),
          (_) => _savePosition(),
        );
      }
    } catch (e) {
      debugPrint("Error playing song: $e");
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

    await _justAudioPlayer.pause();
    _updateNotificationState();
  }

  Future<void> resume() async {
    final song = currentSongNotifier.value;

    // Immediately update the playing state for responsive UI
    isPlayingNotifier.value = true;

    if (song?.filePath != null &&
        _justAudioPlayer.processingState == just_audio.ProcessingState.idle) {
      // Rebuild playlist if needed
      final sources = _buildAudioSources();
      await _justAudioPlayer.setAudioSources(
        sources,
        initialIndex: _currentIndex >= 0 ? _currentIndex : 0,
        preload: true,
      );
      await _justAudioPlayer.seek(positionNotifier.value);
    }
    await _justAudioPlayer.play();
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
    await _justAudioPlayer.seek(position);
    _updateNotificationState();
  }

  Future<void> next() async {
    if (_playlist.isEmpty) return;

    debugPrint(
      'next(): currentIndex=$_currentIndex, playlistLength=${_playlist.length}, loopMode=${loopModeNotifier.value}',
    );

    if (_currentIndex < _playlist.length - 1) {
      _currentIndex++;
      debugPrint('next(): Advancing to index $_currentIndex');
      await play(_playlist[_currentIndex]);
    } else if (loopModeNotifier.value == LoopMode.all) {
      _currentIndex = 0;
      debugPrint('next(): LoopMode.all, wrapping to index 0');
      await play(_playlist[_currentIndex]);
    } else {
      debugPrint('next(): End of playlist, pausing');
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

  /// Rebuild the current playlist with updated settings
  Future<void> _rebuildPlaylist() async {
    if (_playlist.isEmpty || _currentIndex < 0) return;

    try {
      final wasPlaying = isPlayingNotifier.value;
      final currentPosition = positionNotifier.value;

      final sources = _buildAudioSources();

      await _justAudioPlayer.setAudioSources(
        sources,
        initialIndex: _currentIndex,
        preload: true,
      );

      await _justAudioPlayer.seek(currentPosition);
      await _updateLoopMode();

      if (wasPlaying) {
        await _justAudioPlayer.play();
      }
    } catch (e) {
      debugPrint('Error rebuilding playlist: $e');
    }
  }

  /// Update loop mode based on current loop mode setting
  Future<void> _updateLoopMode() async {
    switch (loopModeNotifier.value) {
      case LoopMode.off:
        await _justAudioPlayer.setLoopMode(just_audio.LoopMode.off);
        break;
      case LoopMode.one:
        await _justAudioPlayer.setLoopMode(just_audio.LoopMode.one);
        break;
      case LoopMode.all:
        await _justAudioPlayer.setLoopMode(just_audio.LoopMode.all);
        break;
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

    // Rebuild playlist with new order
    _rebuildPlaylist();
    _updateNotificationState();
  }

  void toggleLoopMode() {
    final modes = LoopMode.values;
    final nextIndex = (loopModeNotifier.value.index + 1) % modes.length;
    loopModeNotifier.value = modes[nextIndex];

    _updateLoopMode();
  }

  // ==================== Volume ====================

  Future<void> setVolume(double volume) async {
    await _justAudioPlayer.setVolume(volume);
  }

  // ==================== Playback Speed ====================

  Future<void> setPlaybackSpeed(double speed) async {
    final clampedSpeed = speed.clamp(0.5, 2.0);
    playbackSpeedNotifier.value = clampedSpeed;
    await _justAudioPlayer.setSpeed(clampedSpeed);
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

    _justAudioPlayer.dispose();

    currentSongNotifier.dispose();
    isPlayingNotifier.dispose();
    positionNotifier.dispose();
    durationNotifier.dispose();
    bufferedPositionNotifier.dispose();
    playbackSpeedNotifier.dispose();
    sleepTimerRemainingNotifier.dispose();
  }
}
