import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/models/playback_state.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/audio_engine.dart';
import 'package:flick/services/rust_audio_service.dart';

typedef RustEngineInitializer = Future<void> Function();
typedef RustEngineDisposer = Future<void> Function();
typedef RustPlaybackPathResolver = Future<String?> Function(Song track);

class RustAudioEngine implements AudioEngine {
  RustAudioEngine({
    required AudioEngineType playbackMode,
    required RustAudioService rustAudioService,
    required RustEngineInitializer ensureInitialized,
    required RustPlaybackPathResolver resolvePlaybackPath,
    required RustEngineDisposer disposeEngine,
  }) : _playbackMode = playbackMode,
       _rustAudioService = rustAudioService,
       _ensureInitialized = ensureInitialized,
       _resolvePlaybackPath = resolvePlaybackPath,
       _disposeEngine = disposeEngine;

  final AudioEngineType _playbackMode;
  final RustAudioService _rustAudioService;
  final RustEngineInitializer _ensureInitialized;
  final RustPlaybackPathResolver _resolvePlaybackPath;
  final RustEngineDisposer _disposeEngine;

  final StreamController<PlaybackState> _controller =
      StreamController<PlaybackState>.broadcast();
  final List<VoidCallback> _notifierUnsubscribers = [];
  late PlaybackState _state = PlaybackState.empty(_playbackMode);
  Song? _loadedTrack;
  Duration? _pendingSeekPosition;

  @override
  Stream<PlaybackState> get playbackStateStream => _controller.stream;

  void _attachListeners() {
    if (_notifierUnsubscribers.isNotEmpty) return;

    void addListener(ValueNotifier<dynamic> notifier, VoidCallback listener) {
      notifier.addListener(listener);
      _notifierUnsubscribers.add(() => notifier.removeListener(listener));
    }

    addListener(_rustAudioService.stateNotifier, () {
      final rustState = _rustAudioService.stateNotifier.value;
      final isPlaying =
          rustState == RustPlaybackState.playing ||
          rustState == RustPlaybackState.crossfading ||
          rustState == RustPlaybackState.buffering;
      _emit(_state.copyWith(isPlaying: isPlaying));
    });

    addListener(_rustAudioService.positionNotifier, () {
      _emit(
        _state.copyWith(position: _rustAudioService.positionNotifier.value),
      );
      _syncBufferedFromLevel();
    });

    addListener(_rustAudioService.durationNotifier, () {
      _emit(
        _state.copyWith(duration: _rustAudioService.durationNotifier.value),
      );
      _syncBufferedFromLevel();
    });

    addListener(_rustAudioService.bufferLevelNotifier, _syncBufferedFromLevel);
  }

  void _syncBufferedFromLevel() {
    final level = _rustAudioService.bufferLevelNotifier.value.clamp(0.0, 1.0);
    final duration = _state.duration;
    if (duration == Duration.zero) return;
    final buffered = Duration(
      milliseconds: (duration.inMilliseconds * level).round(),
    );
    _emit(_state.copyWith(bufferedPosition: buffered));
  }

  void _emit(PlaybackState next) {
    if (next == _state) return;
    _state = next;
    _controller.add(next);
  }

  @override
  Future<void> load(Song track) async {
    await _ensureInitialized();
    _attachListeners();
    _loadedTrack = track;
    _pendingSeekPosition = Duration.zero;
    _emit(
      _state.copyWith(
        currentTrack: track,
        isPlaying: false,
        position: Duration.zero,
        bufferedPosition: Duration.zero,
        duration: track.duration,
      ),
    );
  }

  @override
  Future<void> play() async {
    await _ensureInitialized();
    _attachListeners();
    final track = _loadedTrack;
    if (track == null) {
      final currentPath = _rustAudioService.currentPath;
      if (currentPath == null || currentPath.isEmpty) {
        throw StateError(
          'RustAudioEngine.play() was called before load(track) prepared a source',
        );
      }
      await _rustAudioService.resume();
      return;
    }

    final rustState = _rustAudioService.stateNotifier.value;
    if (rustState == RustPlaybackState.paused) {
      await _rustAudioService.resume();
      final pendingSeek = _pendingSeekPosition;
      if (pendingSeek != null && pendingSeek > Duration.zero) {
        await _rustAudioService.seek(pendingSeek);
      }
      _pendingSeekPosition = null;
      return;
    }

    final path = await _resolvePlaybackPath(track);
    if (path == null || path.isEmpty) {
      throw StateError('Failed to resolve Rust playback path');
    }

    await _rustAudioService.play(path);
    final pendingSeek = _pendingSeekPosition;
    if (pendingSeek != null && pendingSeek > Duration.zero) {
      await _rustAudioService.seek(pendingSeek);
    }
    _pendingSeekPosition = null;
  }

  @override
  Future<void> pause() async {
    await _ensureInitialized();
    _attachListeners();
    await _rustAudioService.pause();
  }

  @override
  Future<void> stop() async {
    await _ensureInitialized();
    _attachListeners();
    await _rustAudioService.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    await _ensureInitialized();
    _attachListeners();
    _pendingSeekPosition = position;
    _emit(_state.copyWith(position: position));

    final rustState = _rustAudioService.stateNotifier.value;
    final canSeekImmediately =
        rustState == RustPlaybackState.playing ||
        rustState == RustPlaybackState.paused ||
        rustState == RustPlaybackState.buffering ||
        rustState == RustPlaybackState.crossfading;
    if (!canSeekImmediately) {
      return;
    }

    await _rustAudioService.seek(position);
  }

  @override
  Future<void> dispose() async {
    for (final remove in _notifierUnsubscribers) {
      remove();
    }
    _notifierUnsubscribers.clear();
    await _disposeEngine();
    await _controller.close();
  }
}
