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

  // Throttled notifier for text labels (updates slower than progress bar)
  // Prevents unnecessary rebuilds of time labels while still providing smooth progress bar
  final ValueNotifier<Duration> positionLabelNotifier = ValueNotifier(
    Duration.zero,
  );
  int _lastPositionLabelMs = 0;

  // Event callbacks
  void Function(String path)? onTrackEnded;
  void Function(String fromPath, String toPath)? onCrossfadeStarted;
  void Function(String path)? onNextTrackReady;
  void Function(String message)? onError;

  Timer? _progressTimer;
  Timer? _eventPollTimer;
  bool _initialized = false;
  bool _highResModeEnabled = false;
  String? _currentPath;
  String? _nextPath;

  /// Check if native audio engine is available on this platform.
  bool get isNativeAvailable => rust_audio.audioIsNativeAvailable();

  /// Initialize the Rust audio engine.
  /// This only boots the manager and event bridge. The heavy native engine is
  /// created lazily on first Rust playback request.
  Future<bool> init() async {
    if (_initialized) return true;

    // Check if native audio is available on this platform
    if (!rust_audio.audioIsNativeAvailable()) {
      debugPrint(
        'Native audio engine not available (expected on mobile platforms)',
      );
      return false;
    }

    try {
      rust_audio.audioInit();
      rust_audio.audioSetHighResMode(enabled: _highResModeEnabled);
      _initialized = true;
      debugPrint('Rust audio engine manager initialized');

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

  /// Whether the user explicitly requested the native high-res engine path.
  bool get isHighResModeEnabled => _highResModeEnabled;

  /// The engine currently selected by the Rust-side manager.
  String get activeEngine => rust_audio.audioGetActiveEngine();

  /// Enable or disable high-res mode.
  Future<void> setHighResMode(bool enabled) async {
    _highResModeEnabled = enabled;
    rust_audio.audioSetHighResMode(enabled: enabled);
  }

  /// Detect whether a DAC is available for the requested output rate.
  Future<bool> isDacAvailable({int? preferredSampleRate}) async {
    if (!isNativeAvailable) return false;

    try {
      return await rust_audio.audioIsDacAvailable(
        preferredSampleRate: preferredSampleRate,
      );
    } catch (e) {
      debugPrint('Error detecting DAC availability: $e');
      return false;
    }
  }

  /// Update the current route capability hint used by the Rust engine manager.
  Future<void> setCapabilityInfo(rust_audio.AudioCapabilityInfo info) async {
    if (!isNativeAvailable) return;

    try {
      rust_audio.audioSetCapabilityInfo(info: info);
    } catch (e) {
      debugPrint('Error updating audio capability info: $e');
    }
  }

  /// Get the merged capability snapshot after local detection and platform hints.
  Future<rust_audio.AudioCapabilityInfo> getCapabilityInfo({
    int? preferredSampleRate,
  }) async {
    if (!isNativeAvailable) {
      return const rust_audio.AudioCapabilityInfo(
        capabilities: [rust_audio.AudioCapabilityType.standard],
        routeType: 'unknown',
        routeLabel: null,
        maxSampleRate: null,
      );
    }

    try {
      return await rust_audio.audioGetCapabilityInfo(
        preferredSampleRate: preferredSampleRate,
      );
    } catch (e) {
      debugPrint('Error reading audio capability info: $e');
      return const rust_audio.AudioCapabilityInfo(
        capabilities: [rust_audio.AudioCapabilityType.standard],
        routeType: 'unknown',
        routeLabel: null,
        maxSampleRate: null,
      );
    }
  }

  bool capabilityInfoPrefersRust(rust_audio.AudioCapabilityInfo info) {
    return info.capabilities.contains(rust_audio.AudioCapabilityType.usbDac) ||
        info.capabilities.contains(
          rust_audio.AudioCapabilityType.hiResInternal,
        );
  }

  /// Resolve whether the native Rust backend should be preferred for playback.
  Future<bool> shouldPreferRustEngine({int? preferredSampleRate}) async {
    final info = await getCapabilityInfo(
      preferredSampleRate: preferredSampleRate,
    );
    return capabilityInfoPrefersRust(info);
  }

  /// Ensure the native engine is fully created for the requested output rate.
  Future<void> prepareEngine({int? preferredSampleRate}) async {
    if (!_initialized) {
      throw StateError('Rust audio engine manager is not initialized');
    }

    try {
      await rust_audio.audioPrepareEngine(
        preferredSampleRate: preferredSampleRate,
      );
    } catch (e) {
      debugPrint('Error preparing Rust audio engine: $e');
      rethrow;
    }
  }

  /// Get the current playback state.
  RustPlaybackState get state => stateNotifier.value;

  /// Get whether audio is currently playing.
  bool get isPlaying =>
      stateNotifier.value == RustPlaybackState.playing ||
      stateNotifier.value == RustPlaybackState.crossfading;

  /// Get the current track path.
  String? get currentPath {
    if (!_initialized) return null;
    try {
      return rust_audio.audioGetCurrentPath();
    } catch (e) {
      debugPrint('Error getting current path: $e');
      return _currentPath; // Fallback to cached value
    }
  }

  /// Play an audio file.
  Future<void> play(String path) async {
    if (!_initialized) {
      throw StateError('Rust audio engine not initialized');
    }

    await rust_audio.audioPlay(path: path);
    _currentPath = path;
    // Also sync from Rust engine to ensure accuracy
    _currentPath = rust_audio.audioGetCurrentPath() ?? path;
    _startProgressUpdates(fast: true);
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
    // Switch to slower updates when paused to reduce CPU usage while keeping UI synced
    _startProgressUpdates(fast: false);
    // Force immediate state update for responsive UI
    _updateState();
  }

  /// Resume playback.
  Future<void> resume() async {
    if (!_initialized) return;
    await rust_audio.audioResume();
    // Resume fast updates for smooth progress bar
    _startProgressUpdates(fast: true);
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
  ///
  /// Note: Uses background timer (not during build) to avoid blocking UI.
  /// The Rust getters (audioGetProgress, audioGetState) are designed to be
  /// cheap read-only operations that return cached state - no blocking I/O.
  /// If progress updates ever cause frame drops, the Rust side should batch
  /// state into a single struct to reduce FFI call overhead.
  void _startProgressUpdates({bool fast = true}) {
    _stopProgressUpdates();

    // Update progress every 50ms for smooth UI updates when playing
    // Update slower (250ms) when paused to keep UI in sync without waste
    final interval = fast
        ? const Duration(milliseconds: 50)
        : const Duration(milliseconds: 250);
    _progressTimer = Timer.periodic(interval, (_) {
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
      final newPositionMs = (progress.positionSecs * 1000).round();
      final currentPositionMs = positionNotifier.value.inMilliseconds;

      // Only update if position actually changed (skip no-op updates)
      if (newPositionMs != currentPositionMs) {
        positionNotifier.value = Duration(milliseconds: newPositionMs);

        // Update label notifier at lower rate (every 500ms)
        if (newPositionMs - _lastPositionLabelMs >= 500) {
          positionLabelNotifier.value = positionNotifier.value;
          _lastPositionLabelMs = newPositionMs;
        }
      }

      if (progress.durationSecs != null) {
        final newDurationMs = (progress.durationSecs! * 1000).round();
        final currentDurationMs = durationNotifier.value.inMilliseconds;

        if (newDurationMs != currentDurationMs) {
          durationNotifier.value = Duration(milliseconds: newDurationMs);
        }
      }

      // Only update buffer level if it actually changed
      final newBufferLevel = progress.bufferLevel;
      if (newBufferLevel != bufferLevelNotifier.value) {
        bufferLevelNotifier.value = newBufferLevel;
      }
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
          final newState = _parseState(state);
          if (stateNotifier.value != newState) {
            stateNotifier.value = newState;
          }

          // Handle state transitions
          if (newState == RustPlaybackState.stopped ||
              newState == RustPlaybackState.idle) {
            _stopProgressUpdates();
          }
        },
        progress: (positionSecs, durationSecs, bufferLevel) {
          final newPositionMs = (positionSecs * 1000).round();
          final currentPositionMs = positionNotifier.value.inMilliseconds;

          if (newPositionMs != currentPositionMs) {
            positionNotifier.value = Duration(milliseconds: newPositionMs);

            // Update label notifier at lower rate
            if (newPositionMs - _lastPositionLabelMs >= 500) {
              positionLabelNotifier.value = positionNotifier.value;
              _lastPositionLabelMs = newPositionMs;
            }
          }

          if (durationSecs != null) {
            final newDurationMs = (durationSecs * 1000).round();
            final currentDurationMs = durationNotifier.value.inMilliseconds;

            if (newDurationMs != currentDurationMs) {
              durationNotifier.value = Duration(milliseconds: newDurationMs);
            }
          }

          if (bufferLevel != bufferLevelNotifier.value) {
            bufferLevelNotifier.value = bufferLevel;
          }
        },
        trackEnded: (path) {
          // Track finished, next track should auto-start if queued
          if (_nextPath != null) {
            _currentPath = _nextPath;
            _nextPath = null;
          } else {
            // Update from Rust engine to ensure sync
            _currentPath = rust_audio.audioGetCurrentPath();
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
    positionLabelNotifier.dispose();
  }
}
