import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flick/src/rust/api/audio_api.dart' as rust_audio;

/// Playback state enum matching the Rust engine states.
enum RustPlaybackState {
  idle,
  playing,
  paused,
  buffering,
  crossfading,
  stopped,
}

/// Service that wraps the Rust audio engine API.
///
/// This provides a clean Dart interface for the native Rust audio engine
/// which supports gapless playback and crossfade.
class RustAudioService {
  static final RustAudioService _instance = RustAudioService._internal();

  factory RustAudioService() => _instance;

  RustAudioService._internal();

  // State notifiers for UI binding
  final ValueNotifier<RustPlaybackState> stateNotifier = ValueNotifier(
    RustPlaybackState.idle,
  );
  final ValueNotifier<Duration> positionNotifier = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> durationNotifier = ValueNotifier(Duration.zero);
  final ValueNotifier<double> bufferLevelNotifier = ValueNotifier(0.0);
  final ValueNotifier<double> volumeNotifier = ValueNotifier(1.0);
  final ValueNotifier<bool> crossfadeEnabledNotifier = ValueNotifier(false);
  final ValueNotifier<double> crossfadeDurationNotifier = ValueNotifier(3.0);
  final ValueNotifier<double> playbackSpeedNotifier = ValueNotifier(1.0);

  // Event callbacks
  void Function(String path)? onTrackEnded;
  void Function(String fromPath, String toPath)? onCrossfadeStarted;
  void Function(String path)? onNextTrackReady;
  void Function(String message)? onError;

  Timer? _progressTimer;
  Timer? _eventPollTimer;
  bool _initialized = false;
  String? _currentPath;
  String? _nextPath;

  /// Check if native audio engine is available on this platform.
  bool get isNativeAvailable => rust_audio.audioIsNativeAvailable();

  /// Initialize the Rust audio engine.
  /// Must be called once at app startup after RustLib.init().
  /// Returns true if initialization succeeded, false if native audio is not available.
  Future<bool> init() async {
    if (_initialized) return true;

    // Check if native audio is available on this platform
    if (!rust_audio.audioIsNativeAvailable()) {
      debugPrint('Native audio engine not available on this platform');
      return false;
    }

    try {
      rust_audio.audioInit();
      _initialized = true;
      debugPrint('Rust audio engine initialized');

      // Start event polling
      _startEventPolling();
      return true;
    } catch (e) {
      debugPrint('Failed to initialize Rust audio engine: $e');
      return false;
    }
  }

  /// Check if the engine is initialized.
  bool get isInitialized => _initialized;

  /// Get the current playback state.
  RustPlaybackState get state => stateNotifier.value;

  /// Get whether audio is currently playing.
  bool get isPlaying =>
      stateNotifier.value == RustPlaybackState.playing ||
      stateNotifier.value == RustPlaybackState.crossfading;

  /// Get the current track path.
  String? get currentPath => _currentPath;

  /// Play an audio file.
  Future<void> play(String path) async {
    if (!_initialized) {
      throw StateError('Rust audio engine not initialized');
    }

    _currentPath = path;
    await rust_audio.audioPlay(path: path);
    _startProgressUpdates();
  }

  /// Queue the next track for gapless playback.
  /// The next track will automatically start when the current one ends.
  Future<void> queueNext(String path) async {
    if (!_initialized) {
      throw StateError('Rust audio engine not initialized');
    }

    _nextPath = path;
    await rust_audio.audioQueueNext(path: path);
  }

  /// Pause playback.
  Future<void> pause() async {
    if (!_initialized) return;
    await rust_audio.audioPause();
    // Force immediate state update for responsive UI
    _updateState();
  }

  /// Resume playback.
  Future<void> resume() async {
    if (!_initialized) return;
    await rust_audio.audioResume();
    _startProgressUpdates();
    // Force immediate state update
    _updateState();
  }

  /// Stop playback completely.
  Future<void> stop() async {
    if (!_initialized) return;
    await rust_audio.audioStop();
    _stopProgressUpdates();
    _currentPath = null;
    _nextPath = null;
  }

  /// Seek to a position in seconds.
  Future<void> seek(Duration position) async {
    if (!_initialized) return;
    await rust_audio.audioSeek(positionSecs: position.inMilliseconds / 1000.0);
  }

  /// Set the volume (0.0 to 1.0).
  Future<void> setVolume(double volume) async {
    if (!_initialized) return;
    final clampedVolume = volume.clamp(0.0, 1.0);
    volumeNotifier.value = clampedVolume;
    await rust_audio.audioSetVolume(volume: clampedVolume);
  }

  /// Enable or disable crossfade.
  Future<void> setCrossfade({
    required bool enabled,
    double? durationSecs,
  }) async {
    if (!_initialized) return;

    crossfadeEnabledNotifier.value = enabled;
    if (durationSecs != null) {
      crossfadeDurationNotifier.value = durationSecs;
    }

    await rust_audio.audioSetCrossfade(
      enabled: enabled,
      durationSecs: crossfadeDurationNotifier.value,
    );
  }

  /// Skip to the next queued track (with crossfade if enabled).
  Future<void> skipToNext() async {
    if (!_initialized) return;
    await rust_audio.audioSkipToNext();
  }

  /// Set the playback speed (0.5 to 2.0).
  Future<void> setPlaybackSpeed(double speed) async {
    if (!_initialized) return;
    final clampedSpeed = speed.clamp(0.5, 2.0);
    playbackSpeedNotifier.value = clampedSpeed;
    await rust_audio.audioSetPlaybackSpeed(speed: clampedSpeed);
  }

  /// Get the current playback speed.
  double getPlaybackSpeed() {
    if (!_initialized) return 1.0;
    return rust_audio.audioGetPlaybackSpeed() ?? 1.0;
  }

  /// Get the sample rate of the audio engine.
  int? getSampleRate() {
    if (!_initialized) return null;
    return rust_audio.audioGetSampleRate();
  }

  /// Get the number of audio channels.
  int? getChannels() {
    if (!_initialized) return null;
    return rust_audio.audioGetChannels()?.toInt();
  }

  /// Shutdown the audio engine.
  Future<void> shutdown() async {
    if (!_initialized) return;

    _stopProgressUpdates();
    _stopEventPolling();
    await rust_audio.audioShutdown();
    _initialized = false;
  }

  /// Start periodic progress updates.
  void _startProgressUpdates() {
    _stopProgressUpdates();

    // Update progress every 50ms for smooth UI updates
    _progressTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      _updateProgress();
    });
  }

  /// Stop progress updates.
  void _stopProgressUpdates() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  /// Update progress from the Rust engine.
  void _updateProgress() {
    final progress = rust_audio.audioGetProgress();
    if (progress != null) {
      positionNotifier.value = Duration(
        milliseconds: (progress.positionSecs * 1000).round(),
      );
      if (progress.durationSecs != null) {
        durationNotifier.value = Duration(
          milliseconds: (progress.durationSecs! * 1000).round(),
        );
      }
      bufferLevelNotifier.value = progress.bufferLevel;
    }

    // Also update state
    _updateState();
  }

  /// Update playback state from the Rust engine.
  void _updateState() {
    final stateStr = rust_audio.audioGetState();
    stateNotifier.value = _parseState(stateStr);
  }

  /// Parse state string to enum.
  RustPlaybackState _parseState(String state) {
    switch (state) {
      case 'playing':
        return RustPlaybackState.playing;
      case 'paused':
        return RustPlaybackState.paused;
      case 'buffering':
        return RustPlaybackState.buffering;
      case 'crossfading':
        return RustPlaybackState.crossfading;
      case 'stopped':
        return RustPlaybackState.stopped;
      default:
        return RustPlaybackState.idle;
    }
  }

  /// Start polling for events from the Rust engine.
  void _startEventPolling() {
    _stopEventPolling();

    // Poll for events every 50ms
    _eventPollTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      _pollEvents();
    });
  }

  /// Stop event polling.
  void _stopEventPolling() {
    _eventPollTimer?.cancel();
    _eventPollTimer = null;
  }

  /// Poll for events from the Rust engine.
  void _pollEvents() {
    while (true) {
      final event = rust_audio.audioPollEvent();
      if (event == null) break;

      event.when(
        stateChanged: (state) {
          stateNotifier.value = _parseState(state);

          // Handle state transitions
          if (stateNotifier.value == RustPlaybackState.stopped ||
              stateNotifier.value == RustPlaybackState.idle) {
            _stopProgressUpdates();
          }
        },
        progress: (positionSecs, durationSecs, bufferLevel) {
          positionNotifier.value = Duration(
            milliseconds: (positionSecs * 1000).round(),
          );
          if (durationSecs != null) {
            durationNotifier.value = Duration(
              milliseconds: (durationSecs * 1000).round(),
            );
          }
          bufferLevelNotifier.value = bufferLevel;
        },
        trackEnded: (path) {
          // Track finished, next track should auto-start if queued
          if (_nextPath != null) {
            _currentPath = _nextPath;
            _nextPath = null;
          }
          onTrackEnded?.call(path);
        },
        crossfadeStarted: (fromPath, toPath) {
          onCrossfadeStarted?.call(fromPath, toPath);
        },
        error: (message) {
          debugPrint('Rust audio error: $message');
          onError?.call(message);
        },
        nextTrackReady: (path) {
          onNextTrackReady?.call(path);
        },
      );
    }
  }

  /// Dispose resources.
  void dispose() {
    _stopProgressUpdates();
    _stopEventPolling();
    stateNotifier.dispose();
    positionNotifier.dispose();
    durationNotifier.dispose();
    bufferLevelNotifier.dispose();
    volumeNotifier.dispose();
    crossfadeEnabledNotifier.dispose();
    crossfadeDurationNotifier.dispose();
    playbackSpeedNotifier.dispose();
  }
}
