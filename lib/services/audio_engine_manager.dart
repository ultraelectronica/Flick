import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/models/playback_state.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/audio_engine.dart';

class AudioEngineManager {
  final StreamController<PlaybackState> _controller =
      StreamController<PlaybackState>.broadcast();

  Stream<PlaybackState> get playbackState => _controller.stream;
  PlaybackState? get latestState => _latestState;
  AudioEngineType? get activeEngineType => _currentEngineType;
  bool get hasAttachedEngine => _currentEngine != null;

  AudioEngine? _currentEngine;
  StreamSubscription<PlaybackState>? _engineSubscription;
  PlaybackState? _latestState;
  AudioEngineType? _currentEngineType;
  bool _engineInitialized = false;
  bool _isTransitioning = false;
  int _attachToken = 0;

  Future<void> attachEngine(
    AudioEngine engine, {
    AudioEngineType? engineType,
    bool disposePrevious = true,
  }) async {
    if (identical(engine, _currentEngine)) {
      return;
    }

    final previousEngine = _currentEngine;
    final previousSubscription = _engineSubscription;
    _currentEngine = engine;

    await previousSubscription?.cancel();
    if (disposePrevious && previousEngine != null) {
      await previousEngine.dispose();
    }

    _attachToken += 1;
    final activeToken = _attachToken;
    final engineLabel = engineType == null
        ? engine.runtimeType.toString()
        : (engineType == AudioEngineType.android ? 'Android' : 'USB');
    _currentEngineType = engineType;
    _engineInitialized = true;
    debugPrint('[Engine] Attached: $engineLabel');

    if (engineType != null) {
      // Preserve the last-known track while the engine is initialising so the
      // UI (mini-player, ambient background) doesn't flash to empty/black.
      final transitional = PlaybackState(
        currentTrack: _latestState?.currentTrack,
        isPlaying: false,
        position: _latestState?.position ?? Duration.zero,
        bufferedPosition: Duration.zero,
        duration: _latestState?.duration ?? Duration.zero,
        engine: engineType,
      );
      _latestState = transitional;
      _controller.add(transitional);
    }

    _engineSubscription = engine.playbackStateStream.listen((state) {
      if (activeToken != _attachToken) return;
      _latestState = state;
      _controller.add(state);
    });
  }

  Future<void> ensureEngine({
    required AudioEngineType engineType,
    required Future<AudioEngine> Function() createEngine,
  }) async {
    if (_engineInitialized &&
        _currentEngine != null &&
        _currentEngineType == engineType) {
      debugPrint('[Engine] Prevented duplicate initialization');
      return;
    }

    if (_isTransitioning) {
      debugPrint('[Engine] Prevented duplicate initialization');
      return;
    }

    _isTransitioning = true;
    try {
      final engine = await createEngine();
      await attachEngine(engine, engineType: engineType);
    } finally {
      _isTransitioning = false;
    }
  }

  Future<void> playTrack(
    Song track, {
    Duration initialPosition = Duration.zero,
    bool autoPlay = true,
  }) async {
    _isTransitioning = true;
    try {
      final engine = _requireEngine();
      debugPrint('[Playback] load(${track.id})');
      await engine.load(track);
      if (initialPosition > Duration.zero) {
        await engine.seek(initialPosition);
      }
      if (autoPlay) {
        debugPrint('[Playback] play()');
        await engine.play();
      }
    } finally {
      _isTransitioning = false;
    }
  }

  void publishIdleState(AudioEngineType engineType) {
    if (_currentEngine != null) {
      return;
    }

    final idleState = PlaybackState.empty(engineType);
    if (_latestState == idleState) {
      return;
    }

    _currentEngineType = engineType;
    _latestState = idleState;
    _controller.add(idleState);
  }

  Future<void> load(Song track) async {
    final engine = _requireEngine();
    debugPrint('[Playback] load(${track.id})');
    await engine.load(track);
  }

  Future<void> play() async {
    final engine = _requireEngine();
    debugPrint('[Playback] play()');
    await engine.play();
  }

  Future<void> pause() async {
    final engine = _requireEngine();
    debugPrint('[Playback] pause()');
    await engine.pause();
  }

  Future<void> stop() async {
    final engine = _requireEngine();
    await engine.stop();
  }

  Future<void> seek(Duration position) async {
    final engine = _requireEngine();
    await engine.seek(position);
  }

  Future<void> dispose() async {
    await _engineSubscription?.cancel();
    _engineSubscription = null;
    if (_currentEngine != null) {
      await _currentEngine!.dispose();
      _currentEngine = null;
    }
    _currentEngineType = null;
    _engineInitialized = false;
    await _controller.close();
  }

  Future<void> detachEngine({bool disposeCurrent = true}) async {
    final previousEngineType = _currentEngineType;
    await _engineSubscription?.cancel();
    _engineSubscription = null;
    if (disposeCurrent && _currentEngine != null) {
      await _currentEngine!.dispose();
    }
    _currentEngine = null;
    _currentEngineType = null;
    _engineInitialized = false;
    _attachToken += 1;
    if (previousEngineType != null) {
      publishIdleState(previousEngineType);
    }
  }

  AudioEngine _requireEngine() {
    final engine = _currentEngine;
    if (engine == null) {
      throw StateError('No audio engine attached');
    }
    return engine;
  }
}
