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

  AudioEngine? _currentEngine;
  StreamSubscription<PlaybackState>? _engineSubscription;
  PlaybackState? _latestState;
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
    debugPrint('[Engine] Attached: $engineLabel');

    if (engineType != null) {
      final cleared = PlaybackState.empty(engineType);
      _latestState = cleared;
      _controller.add(cleared);
    }

    _engineSubscription = engine.playbackStateStream.listen((state) {
      if (activeToken != _attachToken) return;
      _latestState = state;
      _controller.add(state);
    });
  }

  Future<void> load(Song track) async {
    final engine = _requireEngine();
    await engine.load(track);
  }

  Future<void> play() async {
    final engine = _requireEngine();
    await engine.play();
  }

  Future<void> pause() async {
    final engine = _requireEngine();
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
    await _controller.close();
  }

  Future<void> detachEngine({bool disposeCurrent = true}) async {
    await _engineSubscription?.cancel();
    _engineSubscription = null;
    if (disposeCurrent && _currentEngine != null) {
      await _currentEngine!.dispose();
    }
    _currentEngine = null;
  }

  AudioEngine _requireEngine() {
    final engine = _currentEngine;
    if (engine == null) {
      throw StateError('No audio engine attached');
    }
    return engine;
  }
}
