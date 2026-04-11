import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/models/playback_state.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/audio_engine.dart';

typedef AndroidAudioSourcesBuilder =
    Future<List<just_audio.AudioSource>> Function();
typedef AndroidAudioSourceBuilder =
    Future<just_audio.AudioSource> Function(Song track);
typedef AndroidPlaylistProvider = List<Song> Function();
typedef AndroidPlayerProvider = Future<just_audio.AudioPlayer> Function();
typedef AndroidPlayerConfigurator =
    Future<void> Function(just_audio.AudioPlayer player);
typedef AndroidEngineDisposer = Future<void> Function();
typedef AndroidTrackSyncBlocker = bool Function();
typedef AndroidTrackIgnorePredicate = bool Function(Song track);

class AndroidAudioEngine implements AudioEngine {
  AndroidAudioEngine({
    required AndroidPlayerProvider playerProvider,
    required AndroidAudioSourcesBuilder sourcesBuilder,
    required AndroidAudioSourceBuilder sourceBuilder,
    required AndroidPlaylistProvider playlistProvider,
    required AndroidPlayerConfigurator configurePlayer,
    required AndroidEngineDisposer disposeEngine,
    required AndroidTrackSyncBlocker shouldSuppressTrackSync,
    required AndroidTrackIgnorePredicate shouldIgnoreTrack,
  }) : _playerProvider = playerProvider,
       _sourcesBuilder = sourcesBuilder,
       _sourceBuilder = sourceBuilder,
       _playlistProvider = playlistProvider,
       _configurePlayer = configurePlayer,
       _disposeEngine = disposeEngine,
       _shouldSuppressTrackSync = shouldSuppressTrackSync,
       _shouldIgnoreTrack = shouldIgnoreTrack;

  final AndroidPlayerProvider _playerProvider;
  final AndroidAudioSourcesBuilder _sourcesBuilder;
  final AndroidAudioSourceBuilder _sourceBuilder;
  final AndroidPlaylistProvider _playlistProvider;
  final AndroidPlayerConfigurator _configurePlayer;
  final AndroidEngineDisposer _disposeEngine;
  final AndroidTrackSyncBlocker _shouldSuppressTrackSync;
  final AndroidTrackIgnorePredicate _shouldIgnoreTrack;

  final StreamController<PlaybackState> _controller =
      StreamController<PlaybackState>.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  just_audio.AudioPlayer? _player;
  PlaybackState _state = PlaybackState.empty(AudioEngineType.normalAndroid);
  Song? _loadedTrack;
  List<String> _playlistSignature = const <String>[];
  bool _awaitingInitialSeek = false;
  bool _loadedSingleTrackOnly = false;

  static const int _fastStartPlaylistThreshold = 24;

  @override
  Stream<PlaybackState> get playbackStateStream => _controller.stream;

  Future<just_audio.AudioPlayer> _ensurePlayer() async {
    final existing = _player;
    if (existing != null) return existing;
    final player = await _playerProvider();
    _player = player;
    _attachListeners(player);
    return player;
  }

  void _attachListeners(just_audio.AudioPlayer player) {
    _subscriptions.add(
      player.playerStateStream.listen((state) {
        _emit(_state.copyWith(isPlaying: state.playing));
      }),
    );

    _subscriptions.add(
      player.positionStream.listen((pos) {
        _emit(_state.copyWith(position: pos));
        _syncTrackFromIndex(player.currentIndex);
      }),
    );

    _subscriptions.add(
      player.bufferedPositionStream.listen((pos) {
        _emit(_state.copyWith(bufferedPosition: pos));
      }),
    );

    _subscriptions.add(
      player.durationStream.listen((dur) {
        if (dur == null) return;
        _emit(_state.copyWith(duration: dur));
      }),
    );

    _subscriptions.add(
      player.sequenceStateStream.listen((sequenceState) {
        final index = sequenceState.currentIndex;
        _syncTrackFromIndex(index);
      }),
    );

    _subscriptions.add(
      player.currentIndexStream.listen((index) {
        _syncTrackFromIndex(index);
      }),
    );
  }

  void _syncTrackFromIndex(int? index) {
    if (_shouldSuppressTrackSync()) return;
    if (_awaitingInitialSeek) return;
    final nextTrack = _resolveTrack(index);
    if (nextTrack != null && _shouldIgnoreTrack(nextTrack)) {
      return;
    }
    if (nextTrack == _state.currentTrack) return;
    _loadedTrack = nextTrack ?? _loadedTrack;
    _emit(
      _state.copyWith(
        currentTrack: nextTrack,
        position: Duration.zero,
        bufferedPosition: Duration.zero,
        duration: nextTrack?.duration ?? Duration.zero,
      ),
    );
  }

  Song? _resolveTrack(int? index) {
    if (_loadedSingleTrackOnly) {
      return _loadedTrack;
    }
    if (index == null) return _loadedTrack;
    final playlist = _playlistProvider();
    if (index < 0 || index >= playlist.length) {
      return _loadedTrack;
    }
    return playlist[index];
  }

  void _emit(PlaybackState next) {
    if (next == _state) return;
    _state = next;
    _controller.add(next);
  }

  @override
  Future<void> load(Song track) async {
    final player = await _ensurePlayer();
    final playlist = _playlistProvider();
    var index = playlist.indexWhere((song) => song.id == track.id);
    if (index < 0) {
      index = 0;
    }

    final nextSignature = playlist
        .map((song) => song.id)
        .toList(growable: false);
    final canReusePlaylist =
        _playlistSignature.isNotEmpty &&
        listEquals(_playlistSignature, nextSignature);

    _loadedTrack = track;
    await _configurePlayer(player);

    final shouldFastStartCurrentTrackOnly =
        (_loadedSingleTrackOnly || player.sequence.isEmpty) &&
        playlist.length > _fastStartPlaylistThreshold;

    if (canReusePlaylist &&
        player.sequence.isNotEmpty &&
        !_loadedSingleTrackOnly) {
      debugPrint(
        '[Playback] Android load(${track.id}) using existing playlist',
      );
      await player.seek(Duration.zero, index: index);
    } else if (shouldFastStartCurrentTrackOnly) {
      debugPrint(
        '[Playback] Android load(${track.id}) fast-starting current track',
      );
      _awaitingInitialSeek = true;
      try {
        final source = await _sourceBuilder(track);
        await player.setAudioSource(source, preload: true);
        await player.seek(Duration.zero);
      } finally {
        _awaitingInitialSeek = false;
      }
      _loadedSingleTrackOnly = true;
      _playlistSignature = const <String>[];
    } else {
      debugPrint('[Playback] Android load(${track.id}) rebuilding playlist');
      _awaitingInitialSeek = true;
      try {
        final sources = await _sourcesBuilder();
        if (sources.isEmpty) {
          throw StateError('No audio sources available for playback');
        }
        await player.setAudioSources(
          sources,
          initialIndex: index,
          preload: true,
        );
        await player.seek(Duration.zero, index: index);
      } finally {
        _awaitingInitialSeek = false;
      }
      _loadedSingleTrackOnly = false;
      _playlistSignature = nextSignature;
    }

    _emit(
      _state.copyWith(
        currentTrack: track,
        isPlaying: player.playing,
        position: player.position,
        bufferedPosition: player.bufferedPosition,
        duration: player.duration ?? track.duration,
      ),
    );
  }

  @override
  Future<void> play() async {
    final player = await _ensurePlayer();
    // just_audio keeps this future alive while playback is active, which would
    // block the PlayerService command queue until the track ends.
    try {
      final playback = player.play();
      unawaited(
        playback.catchError((Object error, StackTrace stackTrace) {
          debugPrint('[Playback] Android play() failed: $error');
          debugPrintStack(stackTrace: stackTrace);
        }),
      );
    } catch (error, stackTrace) {
      debugPrint('[Playback] Android play() failed immediately: $error');
      debugPrintStack(stackTrace: stackTrace);
      rethrow;
    }
  }

  @override
  Future<void> pause() async {
    final player = await _ensurePlayer();
    await player.pause();
  }

  @override
  Future<void> stop() async {
    final player = await _ensurePlayer();
    await player.stop();
    _emit(
      _state.copyWith(
        isPlaying: player.playing,
        position: player.position,
        bufferedPosition: player.bufferedPosition,
        duration: player.duration ?? _state.duration,
      ),
    );
  }

  @override
  Future<void> seek(Duration position) async {
    final player = await _ensurePlayer();
    await player.seek(position);
  }

  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _player = null;
    _playlistSignature = const <String>[];
    _loadedSingleTrackOnly = false;
    await _disposeEngine();
    await _controller.close();
  }
}
