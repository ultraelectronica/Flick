import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/models/playback_state.dart';
import 'package:flick/models/song.dart';
import 'package:flick/src/rust/api/audio_api.dart' as rust_audio;
import 'package:flick/services/notification_service.dart';
import 'package:flick/services/android_audio_engine.dart';
import 'package:flick/services/android_audio_device_service.dart';
import 'package:flick/services/audio_engine_manager.dart';
import 'package:flick/services/audio_route_manager.dart';
import 'package:flick/services/last_played_service.dart';
import 'package:flick/services/favorites_service.dart';
import 'package:flick/data/repositories/recently_played_repository.dart';
import 'package:flick/services/replay_play_tracker.dart';
import 'package:flick/services/rust_audio_engine.dart';
import 'package:flick/services/rust_audio_service.dart';
import 'package:flick/services/uac2_service.dart';
import 'package:flick/services/alac_converter_service.dart';

/// Loop mode for playback
enum LoopMode { off, one, all }

@visibleForTesting
List<Song> buildShufflePlaybackOrder({
  required List<Song> songs,
  required Song? current,
  math.Random? random,
}) {
  final reordered = List<Song>.from(songs);
  if (reordered.length < 2) return reordered;

  if (current == null) {
    reordered.shuffle(random);
    return reordered;
  }

  final currentIndex = reordered.indexWhere((song) => song.id == current.id);
  if (currentIndex == -1) {
    reordered.shuffle(random);
    return reordered;
  }

  final currentSong = reordered.removeAt(currentIndex);
  reordered.shuffle(random);
  return <Song>[currentSong, ...reordered];
}

@visibleForTesting
List<Song> restorePlaybackOrder({
  required List<Song> originalPlaylist,
  required Song? current,
  required int insertionIndex,
}) {
  final restored = List<Song>.from(originalPlaylist);
  if (current == null) {
    return restored;
  }

  final alreadyPresent = restored.any((song) => song.id == current.id);
  if (!alreadyPresent) {
    restored.insert(insertionIndex.clamp(0, restored.length), current);
  }
  return restored;
}

@visibleForTesting
String canonicalPlaybackFileType({required String fileType, String? filePath}) {
  final pathExtension = extractPlaybackPathExtension(filePath);
  final candidates = <String>[
    if (pathExtension.isNotEmpty) pathExtension,
    if (fileType.trim().isNotEmpty) fileType,
  ];

  for (final candidate in candidates) {
    final normalized = _normalizePlaybackFileTypeCandidate(candidate);
    if (normalized.isNotEmpty) {
      return normalized;
    }
  }

  return '';
}

@visibleForTesting
String extractPlaybackPathExtension(String? path) {
  if (path == null || path.isEmpty) return '';

  final withoutQuery = path.split('?').first.split('#').first;
  final dotIndex = withoutQuery.lastIndexOf('.');
  if (dotIndex < 0 || dotIndex >= withoutQuery.length - 1) return '';
  return withoutQuery.substring(dotIndex + 1).toLowerCase();
}

String _normalizePlaybackFileTypeCandidate(String rawValue) {
  var token = rawValue.trim().toLowerCase();
  if (token.isEmpty) return '';

  final separatorIndex = token.indexOf(';');
  if (separatorIndex >= 0) {
    token = token.substring(0, separatorIndex);
  }

  final slashIndex = token.lastIndexOf('/');
  if (slashIndex >= 0 && slashIndex < token.length - 1) {
    token = token.substring(slashIndex + 1);
  }

  token = token.replaceFirst(RegExp(r'^\.+'), '');
  token = token.trim();

  switch (token) {
    case 'aif':
    case 'aiff':
    case 'x-aiff':
      return 'aiff';
    case 'alac':
    case 'm4a':
    case 'mp4':
    case 'x-m4a':
      return 'm4a';
    case 'ogg':
    case 'oga':
    case 'vorbis':
      return 'ogg';
    case 'ogx':
      return 'ogx';
    case 'opus':
      return 'opus';
    case 'wave':
      return 'wav';
    default:
      return token;
  }
}

@visibleForTesting
bool shouldOptimisticallySyncSkipForLoopMode(LoopMode loopMode) {
  return loopMode != LoopMode.one;
}

@visibleForTesting
bool shouldHandleManualCompletion({
  required bool usingRustBackend,
  required LoopMode loopMode,
}) {
  if (usingRustBackend) {
    return true;
  }

  return loopMode == LoopMode.off;
}

/// Singleton service to manage global audio playback state.
///
/// Uses just_audio for playback with gapless playback support.
class PlayerService {
  static final PlayerService _instance = PlayerService._internal();

  factory PlayerService() {
    return _instance;
  }

  PlayerService._internal() {
    _playbackManager = AudioEngineManager();
    _routeManager = AudioRouteManager(
      onSwitchEngine: _handleEngineSwitch,
      isPlaybackActive: () => isPlayingNotifier.value,
    );
    _bindPlaybackState();
    _init();
  }

  just_audio.AudioPlayer? _justAudioPlayer;
  final List<StreamSubscription<dynamic>> _justAudioSubscriptions =
      <StreamSubscription<dynamic>>[];

  final NotificationService _notificationService = NotificationService();
  final LastPlayedService _lastPlayedService = LastPlayedService();
  final FavoritesService _favoritesService = FavoritesService();
  final RustAudioService _rustAudioService = RustAudioService();
  final Uac2Service _uac2Service = Uac2Service.instance;
  late final AudioRouteManager _routeManager;
  late final AudioEngineManager _playbackManager;
  AndroidAudioEngine? _androidEngine;
  RustAudioEngine? _rustEngine;
  StreamSubscription<PlaybackState>? _playbackStateSubscription;
  PlaybackState? _lastPlaybackState;
  final RecentlyPlayedRepository _recentlyPlayedRepository =
      RecentlyPlayedRepository();
  final ReplayPlayTracker _replayPlayTracker = ReplayPlayTracker();
  static const MethodChannel _storageChannel = MethodChannel(
    'com.ultraelectronica.flick/storage',
  );
  final Map<String, String> _stagedPlaybackPathCache = {};
  final Map<String, String> _convertedPlaybackPathCache = {};
  final Set<String> _unsupportedWavConversionSources = <String>{};
  final ValueNotifier<bool> usingRustBackendNotifier = ValueNotifier(false);
  bool get _usingRustBackend => usingRustBackendNotifier.value;
  set _usingRustBackend(bool value) => usingRustBackendNotifier.value = value;
  bool _rustBackendAvailable = false;
  bool _justAudioListenersAttached = false;
  bool _rustListenersAttached = false;
  bool _audioSessionConfigured = false;
  VoidCallback? _rustStateListener;
  VoidCallback? _rustPositionListener;
  VoidCallback? _rustDurationListener;
  StreamSubscription<AudioInterruptionEvent>? _audioFocusSubscription;
  bool _audioInitialized = false;
  Future<void>? _audioInitInFlight;
  Future<void>? _appLaunchPreparationInFlight;
  Future<void> _playRequestQueue = Future<void>.value();
  Future<bool>? _rustInitInFlight;
  Future<void>? _rustCapabilityRefreshInFlight;
  bool _suppressSequenceStateUpdates = false;
  DateTime? _autoSyncGuardUntil;
  String? _autoSyncGuardSongId;
  String? _restoredSongId;
  Duration _restoredPosition = Duration.zero;
  double _currentVolume = 1.0;

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

  // Queue State
  final ValueNotifier<List<Song>> queueNotifier = ValueNotifier(const []);
  final ValueNotifier<int> currentIndexNotifier = ValueNotifier(-1);
  int _nextQueueEntryId = 0;

  // Sleep Timer
  final ValueNotifier<Duration?> sleepTimerRemainingNotifier = ValueNotifier(
    null,
  );
  Timer? _sleepTimer;
  Timer? _sleepTimerCountdown;

  // Playlist Management
  final List<Song> _playlist = [];
  final List<Song> _originalPlaylist = []; // For shuffle restore
  final List<int?> _playlistQueueEntryIds = [];
  final List<_QueueEntry> _queuedEntries = [];
  int _currentIndex = -1;
  bool _isRebuildingPlaylist =
      false; // Flag to prevent unwanted updates during rebuild

  // Track previous position to detect repeat wrap-around for notification progress
  Duration _lastPosition = Duration.zero;

  // Track last notification update time to throttle updates
  DateTime _lastNotificationUpdate = DateTime.now();

  List<Song> get queue =>
      List.unmodifiable(_queuedEntries.map((entry) => entry.song));
  int get currentIndex => _currentIndex;
  bool get isUsingRustBackend => usingRustBackendNotifier.value;
  List<Song> get upNext {
    if (_playlist.isEmpty) return const [];
    final startIndex = (_currentIndex + 1).clamp(0, _playlist.length);
    return List.unmodifiable(_playlist.sublist(startIndex));
  }

  void _init() {
    // Initialize notification service with callbacks
    _notificationService.init(
      onTogglePlayPause: togglePlayPause,
      onPlay: resume,
      onPause: pause,
      onNext: next,
      onPrevious: previous,
      onStop: _stopPlayback,
      onSeek: seek,
      onToggleShuffle: toggleShuffle,
      onToggleFavorite: _toggleFavoriteFromNotification,
    );
    _notifyQueueChanged();
  }

  void _notifyQueueChanged() {
    queueNotifier.value = List.unmodifiable(
      _queuedEntries.map((entry) => entry.song),
    );
  }

  void _setCurrentIndex(int newIndex) {
    if (_currentIndex == newIndex) return;
    _currentIndex = newIndex;
    currentIndexNotifier.value = newIndex;
  }

  void _replacePlaybackContext(List<Song> songs) {
    _playlist
      ..clear()
      ..addAll(songs);
    _originalPlaylist
      ..clear()
      ..addAll(songs);
    _playlistQueueEntryIds
      ..clear()
      ..addAll(List<int?>.filled(songs.length, null));
  }

  void _insertQueuedEntriesAfterCurrent() {
    if (_queuedEntries.isEmpty || _playlist.isEmpty) return;
    final insertIndex = (_currentIndex + 1).clamp(0, _playlist.length);
    for (var i = 0; i < _queuedEntries.length; i++) {
      final entry = _queuedEntries[i];
      _playlist.insert(insertIndex + i, entry.song);
      _playlistQueueEntryIds.insert(insertIndex + i, entry.id);
    }
  }

  void _consumeQueueEntryAt(int playlistIndex) {
    if (playlistIndex < 0 || playlistIndex >= _playlistQueueEntryIds.length) {
      return;
    }
    final queueEntryId = _playlistQueueEntryIds[playlistIndex];
    if (queueEntryId == null) return;
    _playlistQueueEntryIds[playlistIndex] = null;
    _queuedEntries.removeWhere((entry) => entry.id == queueEntryId);
    _notifyQueueChanged();
  }

  int _findPlaylistIndexForQueueEntry(int queueEntryId) {
    return _playlistQueueEntryIds.indexOf(queueEntryId);
  }

  Future<void> _removeQueueEntryById(int queueEntryId) async {
    final playlistIndex = _findPlaylistIndexForQueueEntry(queueEntryId);
    _queuedEntries.removeWhere((entry) => entry.id == queueEntryId);
    if (playlistIndex != -1) {
      _playlist.removeAt(playlistIndex);
      _playlistQueueEntryIds.removeAt(playlistIndex);
      if (playlistIndex < _currentIndex) {
        _setCurrentIndex(_currentIndex - 1);
      }
    }
    _notifyQueueChanged();
    if (!_usingRustBackend) {
      await _rebuildPlaylist();
    }
  }

  /// Android: current audio session ID from just_audio (for Equalizer attachment).
  /// Null when not set or on non-Android platforms.
  int? get androidAudioSessionId => _justAudioPlayer?.androidAudioSessionId;
  Stream<PlaybackState> get playbackStateStream =>
      _playbackManager.playbackState;
  PlaybackState? get latestPlaybackState => _playbackManager.latestState;
  AudioEngineType get currentEngineType =>
      _routeManager.initializedEngineType ?? _routeManager.selectedEngineType;

  just_audio.AudioPlayer _requireJustAudioPlayer() {
    final player = _justAudioPlayer;
    if (player == null) {
      throw StateError('Android playback engine has not been initialized');
    }
    return player;
  }

  /// Initialize the audio engine.
  /// Sets up just_audio with gapless playback support.
  Future<void> initAudio() async {
    if (_audioInitialized) return;
    final inFlight = _audioInitInFlight;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final future = _initializeAudio();
    _audioInitInFlight = future;
    await future;
  }

  Future<void> prepareForAppLaunch() async {
    final inFlight = _appLaunchPreparationInFlight;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final future = initAudio();

    _appLaunchPreparationInFlight = future;
    try {
      await future;
    } finally {
      _appLaunchPreparationInFlight = null;
    }
  }

  Future<void> setHiFiModeEnabled(bool enabled) async {
    await initAudio();
    await _routeManager.setHiFiModeEnabled(enabled);
  }

  Future<bool> isHiFiModeEnabled() async {
    await initAudio();
    return _routeManager.isHiFiModeEnabled();
  }

  Future<void> _initializeAudio() async {
    debugPrint('[Engine] Initializing audio manager');

    try {
      await _routeManager.initialize();
      _playbackManager.publishIdleState(_routeManager.selectedEngineType);
      await _configureAndroidAudioSession();
      _audioInitialized = true;
    } finally {
      _audioInitInFlight = null;
    }
  }

  Future<void> _configureAndroidAudioSession() async {
    if (!Platform.isAndroid || _audioSessionConfigured) {
      return;
    }

    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    _audioFocusSubscription ??= session.interruptionEventStream.listen((event) {
      if (event.begin) {
        debugPrint('[AudioFocus] lost');
      } else {
        debugPrint('[AudioFocus] gained');
      }
    });
    _audioSessionConfigured = true;
  }

  Future<bool> _ensureRustBackendAvailable() async {
    if (_rustBackendAvailable) return true;
    if (_rustInitInFlight != null) {
      return _rustInitInFlight!;
    }

    final completer = Completer<bool>();
    _rustInitInFlight = completer.future;

    try {
      _rustBackendAvailable = await _rustAudioService.init();
      return _rustBackendAvailable;
    } catch (e) {
      _rustBackendAvailable = false;
      debugPrint('Rust audio backend unavailable: $e');
      return false;
    } finally {
      completer.complete(_rustBackendAvailable);
      _rustInitInFlight = null;
    }
  }

  Future<void> _refreshRustCapabilityInfo() async {
    if (!Platform.isAndroid) return;

    final inFlight = _rustCapabilityRefreshInFlight;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final future = () async {
      final rustAvailable = await _ensureRustBackendAvailable();
      if (!rustAvailable) return;

      final capabilityInfo = await _uac2Service.getAndroidAudioCapabilityInfo();
      await _applyRustCapabilityInfo(capabilityInfo);
    }();

    _rustCapabilityRefreshInFlight = future;
    try {
      await future;
    } finally {
      if (identical(_rustCapabilityRefreshInFlight, future)) {
        _rustCapabilityRefreshInFlight = null;
      }
    }
  }

  Future<void> _applyRustCapabilityInfo(
    rust_audio.AudioCapabilityInfo capabilityInfo, {
    int? prewarmSampleRate,
  }) async {
    await _rustAudioService.setCapabilityInfo(
      rust_audio.AudioCapabilityInfo(
        capabilities: capabilityInfo.capabilities,
        routeType: capabilityInfo.routeType,
        routeLabel: capabilityInfo.routeLabel,
        maxSampleRate: prewarmSampleRate,
      ),
    );
  }

  Uac2AudioFormat? _deriveUac2FormatFromSong(Song? song) {
    if (song == null) return null;

    final structuredSampleRate = song.sampleRate;
    final structuredBitDepth = song.bitDepth;
    if (structuredSampleRate != null || structuredBitDepth != null) {
      return Uac2AudioFormat(
        sampleRate: structuredSampleRate ?? 44100,
        bitDepth: structuredBitDepth ?? 16,
        channels: 2,
      );
    }

    final resolution = song.resolution ?? '';
    final bitDepthMatch = RegExp(
      r'(\d+)-bit',
      caseSensitive: false,
    ).firstMatch(resolution);
    final sampleRateMatch = RegExp(
      r'(\d+(?:\.\d+)?)\s*kHz',
      caseSensitive: false,
    ).firstMatch(resolution);

    final bitDepth = int.tryParse(bitDepthMatch?.group(1) ?? '');
    final sampleRateKhz = double.tryParse(sampleRateMatch?.group(1) ?? '');
    final sampleRate = sampleRateKhz != null
        ? (sampleRateKhz * 1000).round()
        : null;

    if (bitDepth == null && sampleRate == null) return null;

    return Uac2AudioFormat(
      sampleRate: sampleRate ?? 44100,
      bitDepth: bitDepth ?? 16,
      channels: 2,
    );
  }

  Future<void> _syncUac2PlaybackStatus(
    Song? song, {
    required bool isPlaying,
  }) async {
    await _uac2Service.syncPlaybackStatus(
      song: song,
      isPlaying: isPlaying,
      formatOverride: _deriveUac2FormatFromSong(song),
    );
  }

  void _setupJustAudioListeners() {
    if (_justAudioListenersAttached) return;
    _justAudioListenersAttached = true;

    final player = _requireJustAudioPlayer();

    _justAudioSubscriptions.add(
      player.errorStream.listen((error) {
        if (_usingRustBackend) return;
        final song = currentSongNotifier.value;
        if (song == null) return;
        final message = error.toString();
        if (message.contains('Loading interrupted')) {
          debugPrint(
            'Ignoring just_audio interruption for ${song.title} during player transition',
          );
          return;
        }

        debugPrint('just_audio error for ${song.title}: $error');
      }),
    );

    _justAudioSubscriptions.add(
      player.playerStateStream.listen((state) {
        if (_usingRustBackend) return;
        final wasPlaying = isPlayingNotifier.value;
        unawaited(
          _syncUac2PlaybackStatus(
            currentSongNotifier.value,
            isPlaying: state.playing,
          ),
        );

        if (wasPlaying != state.playing && currentSongNotifier.value != null) {
          // Update full notification state to ensure icon and time update properly
          _updateNotificationState();
        }

        if (!_suppressSequenceStateUpdates &&
            state.processingState == just_audio.ProcessingState.completed &&
            shouldHandleManualCompletion(
              usingRustBackend: false,
              loopMode: loopModeNotifier.value,
            )) {
          _onSongFinished();
        }
      }),
    );

    _justAudioSubscriptions.add(
      player.positionStream.listen((pos) {
        if (_usingRustBackend) return;
        if (!_suppressSequenceStateUpdates) {
          final activeIndex = player.currentIndex;
          if (activeIndex != null && activeIndex != _currentIndex) {
            _syncCurrentSongFromIndex(activeIndex, fromListener: true);
          }
        }

        // When repeat-one loops, just_audio may not fire completed; detect
        // position wrapping back to start so the notification progress bar resets.
        final prev = _lastPosition;
        _lastPosition = pos;
        _updateAutoSyncGuardFromProgress(pos);
        _trackReplayProgress(pos);

        // Update notification on loop wrap-around
        if (currentSongNotifier.value != null &&
            durationNotifier.value.inSeconds > 0 &&
            prev.inSeconds > 5 &&
            pos.inSeconds < 2) {
          _updateNotificationState();
        }

        // Periodically update notification with current position (throttled to every 2 seconds)
        final now = DateTime.now();
        if (currentSongNotifier.value != null &&
            isPlayingNotifier.value &&
            now.difference(_lastNotificationUpdate).inSeconds >= 2) {
          _lastNotificationUpdate = now;
          _updateNotificationState();
        }
      }),
    );

    _justAudioSubscriptions.add(
      player.bufferedPositionStream.listen((pos) {
        if (_usingRustBackend) return;
      }),
    );

    _justAudioSubscriptions.add(
      player.durationStream.listen((dur) {
        if (_usingRustBackend) return;
        if (dur != null) {
          if (currentSongNotifier.value != null && isPlayingNotifier.value) {
            _updateNotificationState();
          }
        }
      }),
    );

    // Listen to sequence state changes for gapless transitions
    _justAudioSubscriptions.add(
      player.sequenceStateStream.listen((sequenceState) {
        if (_usingRustBackend) return;
        // Skip updates during playlist rebuild to prevent wrong song display
        if (_isRebuildingPlaylist || _suppressSequenceStateUpdates) return;

        if (sequenceState.currentIndex != null) {
          _syncCurrentSongFromIndex(
            sequenceState.currentIndex!,
            fromListener: true,
          );
        }
      }),
    );

    // Some engines/transition paths may emit currentIndex without a matching
    // sequenceState transition callback timing. Keep UI in sync either way.
    _justAudioSubscriptions.add(
      player.currentIndexStream.listen((newIndex) {
        if (_usingRustBackend) return;
        if (_isRebuildingPlaylist || _suppressSequenceStateUpdates) return;
        if (newIndex == null) return;
        _syncCurrentSongFromIndex(newIndex, fromListener: true);
      }),
    );

    _justAudioSubscriptions.add(
      player.positionDiscontinuityStream.listen((discontinuity) {
        if (_usingRustBackend) return;
        if (_isRebuildingPlaylist || _suppressSequenceStateUpdates) return;
        if (discontinuity.reason !=
            just_audio.PositionDiscontinuityReason.autoAdvance) {
          return;
        }

        final newIndex = discontinuity.event.currentIndex;
        if (newIndex == null) return;
        _syncCurrentSongFromIndex(newIndex, fromListener: true);
      }),
    );
  }

  void _syncCurrentSongFromIndex(int newIndex, {bool fromListener = false}) {
    if (newIndex < 0 || newIndex >= _playlist.length) return;

    final newSong = _playlist[newIndex];
    if (fromListener && _shouldIgnoreAutoSyncedSong(newSong)) {
      debugPrint(
        'Ignoring transient auto-sync to ${newSong.title} during explicit play handoff',
      );
      return;
    }

    // Keep index and queue state synced even when _currentIndex was
    // already moved by next()/previous() before stream events arrive.
    if (newIndex != _currentIndex) {
      _setCurrentIndex(newIndex);
    }
    _consumeQueueEntryAt(newIndex);

    if (_autoSyncGuardSongId == newSong.id) {
      _clearAutoSyncGuard();
    }
    if (newSong != currentSongNotifier.value) {
      debugPrint(
        'Track transition: ${currentSongNotifier.value?.title} -> ${newSong.title}',
      );
    }
  }

  void _startReplayTracking(
    Song song, {
    Duration initialPosition = Duration.zero,
  }) {
    _replayPlayTracker.startTrack(song.id, initialPosition: initialPosition);
  }

  void _clearReplayTracking() {
    _replayPlayTracker.clear();
  }

  void _trackReplayProgress(Duration position) {
    final song = currentSongNotifier.value;
    if (song == null) {
      _clearReplayTracking();
      return;
    }

    if (!isPlayingNotifier.value) {
      _replayPlayTracker.syncPosition(songId: song.id, position: position);
      return;
    }

    final counted = _replayPlayTracker.onPositionChanged(
      songId: song.id,
      position: position,
    );
    if (counted) {
      unawaited(_recentlyPlayedRepository.recordPlay(song.id));
    }
  }

  void _setupRustAudioListeners() {
    if (_rustListenersAttached) return;
    _rustListenersAttached = true;

    _rustStateListener = () {
      if (!_usingRustBackend) return;

      final rustState = _rustAudioService.stateNotifier.value;
      final isPlaying =
          rustState == RustPlaybackState.playing ||
          rustState == RustPlaybackState.crossfading;

      unawaited(
        _syncUac2PlaybackStatus(
          currentSongNotifier.value,
          isPlaying: isPlaying,
        ),
      );
    };
    _rustAudioService.stateNotifier.addListener(_rustStateListener!);

    _rustPositionListener = () {
      if (!_usingRustBackend) return;

      final pos = _rustAudioService.positionNotifier.value;
      _trackReplayProgress(pos);

      final now = DateTime.now();
      if (currentSongNotifier.value != null &&
          isPlayingNotifier.value &&
          now.difference(_lastNotificationUpdate).inSeconds >= 2) {
        _lastNotificationUpdate = now;
        _updateNotificationState();
      }
    };
    _rustAudioService.positionNotifier.addListener(_rustPositionListener!);

    _rustDurationListener = () {
      if (!_usingRustBackend) return;
    };
    _rustAudioService.durationNotifier.addListener(_rustDurationListener!);

    _rustAudioService.onTrackEnded = (_) {
      if (!_usingRustBackend) return;
      _onSongFinished();
    };
  }

  void _bindPlaybackState() {
    _playbackStateSubscription?.cancel();
    _playbackStateSubscription = _playbackManager.playbackState.listen((state) {
      final previous = _lastPlaybackState;
      _lastPlaybackState = state;

      if (currentSongNotifier.value != state.currentTrack) {
        currentSongNotifier.value = state.currentTrack;
      }
      if (isPlayingNotifier.value != state.isPlaying) {
        isPlayingNotifier.value = state.isPlaying;
      }
      if (positionNotifier.value != state.position) {
        positionNotifier.value = state.position;
      }
      if (bufferedPositionNotifier.value != state.bufferedPosition) {
        bufferedPositionNotifier.value = state.bufferedPosition;
      }
      if (durationNotifier.value != state.duration) {
        durationNotifier.value = state.duration;
      }

      final shouldUseRust = state.engine == AudioEngineType.usb;
      if (_usingRustBackend != shouldUseRust) {
        _usingRustBackend = shouldUseRust;
      }

      final previousTrackId = previous?.currentTrack?.id;
      final currentTrackId = state.currentTrack?.id;
      if (previousTrackId != currentTrackId) {
        if (currentTrackId != null && currentTrackId == _restoredSongId) {
          _clearRestoredPlaybackContext(songId: currentTrackId);
        }
        if (_autoSyncGuardSongId != null &&
            _autoSyncGuardSongId == currentTrackId) {
          _clearAutoSyncGuard();
        }
        if (state.currentTrack != null) {
          debugPrint('[Playback] Track changed: ${state.currentTrack!.title}');
        } else {
          debugPrint('[Playback] Track cleared');
        }
        if (state.currentTrack != null) {
          _startReplayTracking(
            state.currentTrack!,
            initialPosition: state.position,
          );
          unawaited(
            _syncUac2PlaybackStatus(
              state.currentTrack,
              isPlaying: state.isPlaying,
            ),
          );
          unawaited(_updateNotificationState());
          unawaited(
            _savePosition(song: state.currentTrack, position: state.position),
          );
        } else {
          _clearReplayTracking();
        }
      } else if (previous?.isPlaying != state.isPlaying &&
          state.currentTrack != null) {
        unawaited(_updateNotificationState());
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

    var isFav = false;
    try {
      isFav = await _favoritesService.isFavorite(song.id);
    } catch (e) {
      debugPrint('Failed to load favorite state: $e');
    }

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
    _clearReplayTracking();
    try {
      await _playbackManager.stop();
    } catch (e) {
      debugPrint('Stop failed: $e');
    }
    cancelSleepTimer();
  }

  /// Build audio sources for the playlist (gapless playback).
  Future<List<just_audio.AudioSource>> _buildAudioSources() async {
    if (_playlist.isEmpty) return const [];

    const batchSize = 12;
    final sources = <just_audio.AudioSource>[];

    for (var start = 0; start < _playlist.length; start += batchSize) {
      final end = (start + batchSize).clamp(0, _playlist.length);
      final batch = _playlist.sublist(start, end);
      final resolvedBatch = await Future.wait(
        batch.map(_buildAudioSourceForSong),
      );
      sources.addAll(resolvedBatch);
    }

    return sources;
  }

  Future<just_audio.AudioSource> _buildAudioSourceForSong(Song song) async {
    if (song.filePath == null) {
      return just_audio.AudioSource.uri(Uri.parse(''));
    }

    final uri = await _resolvePlaybackUri(song);
    return just_audio.AudioSource.uri(uri);
  }

  Future<Uri> _resolvePlaybackUri(Song song) async {
    final resolvedPath = await _resolvePreparedPlaybackPath(song);
    if (resolvedPath == null || resolvedPath.isEmpty) {
      return Uri.parse('');
    }

    return _toPlaybackUri(resolvedPath);
  }

  Future<String?> _resolvePreparedPlaybackPath(Song song) async {
    final filePath = song.filePath;
    if (filePath == null || filePath.isEmpty) {
      return null;
    }

    final sourceKey = filePath;
    var resolvedPath = filePath;
    final parsed = Uri.tryParse(filePath);
    final isAndroidContentUri =
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        parsed?.scheme == 'content';

    // SAF-backed URIs for ALAC/AIFF/M4A can fail format detection in some
    // decoder paths. Stage them to a local temp file with a stable extension.
    if (isAndroidContentUri && _shouldStageForPlayback(song)) {
      final stagedPath = await _stageContentUriForPlayback(
        filePath,
        extensionHint: _preferredExtension(song),
      );
      if (stagedPath != null) {
        resolvedPath = stagedPath;
      }
    }

    if (_shouldConvertToWav(song)) {
      final convertedPath = await _convertPlaybackPathToWav(
        sourceKey: sourceKey,
        sourcePath: resolvedPath,
      );
      if (convertedPath != null) {
        resolvedPath = convertedPath;
      }
    }

    return resolvedPath;
  }

  bool _shouldStageForPlayback(Song song) {
    final normalized = _playbackFileType(song);
    return normalized == 'm4a' || normalized == 'aiff';
  }

  Future<String?> _stageContentUriForPlayback(
    String uri, {
    required String extensionHint,
  }) async {
    final cached = _stagedPlaybackPathCache[uri];
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    try {
      final stagedPath = await _storageChannel.invokeMethod<String>(
        'cacheUriForPlayback',
        {'uri': uri, 'extensionHint': extensionHint},
      );
      if (stagedPath != null && stagedPath.isNotEmpty) {
        _stagedPlaybackPathCache[uri] = stagedPath;
        return stagedPath;
      }
    } catch (e) {
      debugPrint('Failed to stage content URI for playback: $e');
    }
    return null;
  }

  String _preferredExtension(Song song) {
    final fileType = _playbackFileType(song);
    if (fileType == 'aiff' || fileType == 'm4a') return fileType;
    if (RegExp(r'^[a-z0-9]+$').hasMatch(fileType) && fileType.isNotEmpty) {
      return fileType;
    }

    final filePath = song.filePath;
    if (filePath != null) {
      final extension = extractPlaybackPathExtension(filePath);
      if (extension.isNotEmpty) {
        return extension;
      }
    }
    return 'm4a';
  }

  Uri _toPlaybackUri(String rawPath) {
    // Handle Windows absolute paths like C:\Music\song.flac.
    if (RegExp(r'^[a-zA-Z]:\\').hasMatch(rawPath)) {
      return Uri.file(rawPath, windows: true);
    }

    final parsed = Uri.tryParse(rawPath);
    if (parsed != null && parsed.scheme.isNotEmpty) {
      return parsed;
    }

    // Local filesystem path.
    return Uri.file(rawPath);
  }

  bool _shouldConvertToWav(Song song) {
    final normalized = _playbackFileType(song);
    return normalized == 'm4a' || normalized == 'aiff';
  }

  Future<String?> _convertPlaybackPathToWav({
    required String sourceKey,
    required String sourcePath,
  }) async {
    if (_unsupportedWavConversionSources.contains(sourceKey)) {
      return null;
    }

    final cached = _convertedPlaybackPathCache[sourceKey];
    if (cached != null && cached.isNotEmpty) {
      final cachedFile = Uri.file(cached).toFilePath();
      if (await File(cachedFile).exists()) {
        return cached;
      }
      _convertedPlaybackPathCache.remove(sourceKey);
    }

    final playbackUri = _toPlaybackUri(sourcePath);
    if (playbackUri.scheme != 'file') {
      return null;
    }

    final localPath = playbackUri.toFilePath();
    final canConvert = await AlacConverterService.canConvertToWavFile(
      localPath,
    );
    if (!canConvert) {
      _unsupportedWavConversionSources.add(sourceKey);
      return null;
    }

    try {
      final convertedPath = await AlacConverterService.convertToWavFile(
        localPath,
      );
      _convertedPlaybackPathCache[sourceKey] = convertedPath;
      _unsupportedWavConversionSources.remove(sourceKey);
      return convertedPath;
    } catch (e) {
      _unsupportedWavConversionSources.add(sourceKey);
      debugPrint('Failed to convert playback path to WAV: $e');
      return null;
    }
  }

  String _playbackFileType(Song song) {
    return canonicalPlaybackFileType(
      fileType: song.fileType,
      filePath: song.filePath,
    );
  }

  Future<String?> _resolveRustPath(Song song) async {
    final resolvedPath = await _resolvePreparedPlaybackPath(song);
    if (resolvedPath == null || resolvedPath.isEmpty) return null;

    final uri = _toPlaybackUri(resolvedPath);
    if (uri.scheme == 'file') {
      return uri.toFilePath();
    }

    if (uri.scheme.isEmpty) {
      return resolvedPath;
    }

    return null;
  }

  Future<void> _prepareImmediatePlaybackAsset(Song song) async {
    if (!_shouldStageForPlayback(song) && !_shouldConvertToWav(song)) {
      return;
    }

    await _resolvePreparedPlaybackPath(song);
  }

  Future<just_audio.AudioPlayer> _ensureAndroidEngineInitialized() async {
    final existingPlayer = _justAudioPlayer;
    if (existingPlayer != null) {
      return existingPlayer;
    }

    await _configureAndroidAudioSession();
    debugPrint('[Engine] Initializing Android engine');
    final player = just_audio.AudioPlayer(
      handleInterruptions: true,
      androidApplyAudioAttributes: true,
      handleAudioSessionActivation: true,
    );
    _justAudioPlayer = player;
    _setupJustAudioListeners();
    await player.setVolume(_currentVolume);
    await _updateLoopMode();
    return player;
  }

  Future<void> _configureAndroidPlayer(just_audio.AudioPlayer player) async {
    await player.setSpeed(playbackSpeedNotifier.value);
    await player.setVolume(_currentVolume);
    await _updateLoopMode();
  }

  AndroidAudioEngine _createAndroidEngine() {
    return AndroidAudioEngine(
      playerProvider: _ensureAndroidEngineInitialized,
      sourcesBuilder: _buildAudioSources,
      playlistProvider: () => List<Song>.from(_playlist),
      configurePlayer: _configureAndroidPlayer,
      disposeEngine: _disposeAndroidEngine,
      shouldSuppressTrackSync: () =>
          _isRebuildingPlaylist || _suppressSequenceStateUpdates,
      shouldIgnoreTrack: _shouldIgnoreAutoSyncedSong,
    );
  }

  RustAudioEngine _createRustEngine() {
    return RustAudioEngine(
      rustAudioService: _rustAudioService,
      ensureInitialized: _ensureUsbEngineInitialized,
      resolvePlaybackPath: _resolveRustPath,
      disposeEngine: _disposeUsbEngine,
    );
  }

  Future<void> _ensureUsbEngineInitialized() async {
    if (Platform.isAndroid) {
      final deviceInfo = await AndroidAudioDeviceService.instance.refresh();
      if (!deviceInfo.hasUsbDac) {
        debugPrint('[Engine] USB init blocked: no USB DAC detected');
        throw StateError('Rust USB engine requires a USB DAC');
      }
    }

    if (!_rustAudioService.isInitialized) {
      debugPrint('[Engine] Initializing USB engine');
    }

    final rustAvailable = await _ensureRustBackendAvailable();
    if (!rustAvailable) {
      throw StateError('Rust USB engine is unavailable');
    }

    if (Platform.isAndroid) {
      await _uac2Service.initialize();
      await _refreshRustCapabilityInfo();
    }

    _setupRustAudioListeners();
  }

  Future<void> _disposeAndroidEngine() async {
    final player = _justAudioPlayer;
    if (player == null) return;

    debugPrint('[Engine] Disposing Android engine');
    final subscriptions = List<StreamSubscription<dynamic>>.from(
      _justAudioSubscriptions,
    );
    _justAudioSubscriptions.clear();
    _justAudioListenersAttached = false;

    for (final subscription in subscriptions) {
      await subscription.cancel();
    }

    try {
      await player.stop();
    } catch (_) {}

    await player.dispose();
    _justAudioPlayer = null;
  }

  Future<void> _disposeUsbEngine() async {
    if (!_rustAudioService.isInitialized) return;

    debugPrint('[Engine] Disposing USB engine');
    if (_rustListenersAttached) {
      if (_rustStateListener != null) {
        _rustAudioService.stateNotifier.removeListener(_rustStateListener!);
      }
      if (_rustPositionListener != null) {
        _rustAudioService.positionNotifier.removeListener(
          _rustPositionListener!,
        );
      }
      if (_rustDurationListener != null) {
        _rustAudioService.durationNotifier.removeListener(
          _rustDurationListener!,
        );
      }
      _rustStateListener = null;
      _rustPositionListener = null;
      _rustDurationListener = null;
      _rustListenersAttached = false;
    }
    try {
      await _rustAudioService.stop();
    } catch (_) {}

    try {
      await _rustAudioService.shutdown();
    } catch (_) {}

    _usingRustBackend = false;
  }

  Future<void> _handleEngineSwitch({
    required AudioEngineType? from,
    required AudioEngineType to,
    required bool initializeNewEngine,
    required String reason,
  }) async {
    if (!initializeNewEngine) {
      await _playbackManager.detachEngine();
      _usingRustBackend = false;
      return;
    }

    await _playbackManager.ensureEngine(
      engineType: to,
      createEngine: () async {
        switch (to) {
          case AudioEngineType.android:
            _androidEngine = _createAndroidEngine();
            return _androidEngine!;
          case AudioEngineType.usb:
            _rustEngine = _createRustEngine();
            return _rustEngine!;
        }
      },
    );
    _usingRustBackend = to == AudioEngineType.usb;

    debugPrint(
      '[Engine] Switch complete: ${from?.name ?? 'none'} -> ${to.name} ($reason)',
    );
  }

  Song? _songAtCurrentIndex() {
    if (_currentIndex < 0 || _currentIndex >= _playlist.length) {
      return null;
    }
    return _playlist[_currentIndex];
  }

  void _rememberRestoredPlaybackContext(Song song, Duration position) {
    _restoredSongId = song.id;
    _restoredPosition = position;
  }

  Duration _consumeRestoredPositionForSong(Song song) {
    if (_restoredSongId != song.id) {
      return Duration.zero;
    }

    final restoredPosition = _restoredPosition;
    _clearRestoredPlaybackContext(songId: song.id);
    return restoredPosition;
  }

  void _clearRestoredPlaybackContext({String? songId}) {
    if (songId != null && _restoredSongId != songId) {
      return;
    }

    _restoredSongId = null;
    _restoredPosition = Duration.zero;
  }

  Future<AudioEngineType> _normalizeRequestedEngine(
    AudioEngineType desiredEngine, {
    required String reason,
  }) async {
    if (desiredEngine != AudioEngineType.usb || !Platform.isAndroid) {
      return desiredEngine;
    }

    final deviceInfo = await AndroidAudioDeviceService.instance.refresh();
    if (deviceInfo.hasUsbDac) {
      return desiredEngine;
    }

    debugPrint(
      '[Engine] USB engine requested without a USB DAC; '
      'falling back to Android ($reason)',
    );
    return AudioEngineType.android;
  }

  Future<AudioEngineType> _ensureEngineReady(
    AudioEngineType desiredEngine, {
    required String reason,
  }) async {
    final normalizedEngine = await _normalizeRequestedEngine(
      desiredEngine,
      reason: reason,
    );
    await _routeManager.switchEngine(
      normalizedEngine,
      initializeNewEngine: true,
      reason: reason,
    );
    return normalizedEngine;
  }

  /// Play a specific song.
  Future<void> play(Song song, {List<Song>? playlist}) {
    debugPrint('[UI] tap(${song.id})');
    return _enqueuePlaybackRequest(
      () => _playInternal(song, playlist: playlist),
    );
  }

  Future<void> _enqueuePlaybackRequest(Future<void> Function() action) {
    final operation = _playRequestQueue.then<void>((_) => action());
    _playRequestQueue = operation.catchError((_) {});
    return operation;
  }

  Future<void> _playInternal(Song song, {List<Song>? playlist}) async {
    await initAudio();
    try {
      debugPrint(
        '[Playback] play() called for ${song.title} '
        '(selected engine: ${_routeManager.selectedEngineType.name})',
      );

      _positionSaveTimer?.cancel();

      if (playlist != null) {
        _replacePlaybackContext(playlist);
        _setCurrentIndex(_playlist.indexWhere((entry) => entry.id == song.id));
        _insertQueuedEntriesAfterCurrent();
      } else {
        final existingIndex = _playlist.indexWhere(
          (entry) => entry.id == song.id,
        );
        if (existingIndex == -1) {
          _replacePlaybackContext([song]);
          _setCurrentIndex(0);
          _insertQueuedEntriesAfterCurrent();
        } else {
          _setCurrentIndex(existingIndex);
        }
      }

      if (_currentIndex == -1) {
        _setCurrentIndex(0);
      }

      _armAutoSyncGuard(song);
      _consumeQueueEntryAt(_currentIndex);
      _clearRestoredPlaybackContext(songId: song.id);

      if (song.filePath != null) {
        await _prepareImmediatePlaybackAsset(song);
        final desiredEngine = await _routeManager.resolvePreferredEngineType(
          refresh: true,
        );
        final activeEngine = await _ensureEngineReady(
          desiredEngine,
          reason: 'playback requested',
        );
        debugPrint('[Engine] Playback route resolved to ${activeEngine.name}');
        await _playbackManager.playTrack(song);
        _ensurePositionSaveTimer();
      }
    } catch (e, stackTrace) {
      debugPrint(
        '[Playback] play() failed for ${song.title} '
        'on ${currentEngineType.name}: $e',
      );
      debugPrintStack(stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<void> _playSongAtCurrentIndex() async {
    final song = _songAtCurrentIndex();
    if (song == null) {
      return;
    }
    await _playInternal(song);
  }

  Future<void> _savePosition({Song? song, Duration? position}) async {
    final resolvedSong = song ?? currentSongNotifier.value;
    if (resolvedSong == null) return;

    try {
      await _lastPlayedService.saveLastPlayed(
        resolvedSong.id,
        position ?? positionNotifier.value,
        playlistSongIds: _playlist.map((s) => s.id).toList(),
        currentIndex: _currentIndex,
        wasPlaying: isPlayingNotifier.value,
      );
    } catch (e) {
      debugPrint('Failed to save last played position: $e');
    }
  }

  Future<void> persistLastPlayed() async {
    await _savePosition();
  }

  Future<void> restoreLastPlayed() async {
    if (currentSongNotifier.value != null || isPlayingNotifier.value) {
      return;
    }

    final lastPlayed = await _lastPlayedService.getLastPlayed();
    if (lastPlayed != null) {
      if (currentSongNotifier.value != null || isPlayingNotifier.value) {
        return;
      }

      final restoredPlaylist = lastPlayed.playlist;

      if (restoredPlaylist != null && restoredPlaylist.isNotEmpty) {
        _replacePlaybackContext(restoredPlaylist);
        final fallbackIndex = restoredPlaylist.indexWhere(
          (song) => song.id == lastPlayed.song.id,
        );
        _setCurrentIndex(
          lastPlayed.playlistIndex ?? (fallbackIndex >= 0 ? fallbackIndex : 0),
        );
      } else {
        _replacePlaybackContext([lastPlayed.song]);
        _setCurrentIndex(0);
      }

      if (_currentIndex < 0 || _currentIndex >= _playlist.length) {
        _setCurrentIndex(0);
      }

      final restoredSong = _playlist[_currentIndex];
      _rememberRestoredPlaybackContext(restoredSong, lastPlayed.position);

      if (restoredSong.filePath != null) {
        debugPrint(
          '[Playback] Restored ${restoredSong.title} at '
          '${lastPlayed.position.inMilliseconds}ms; waiting for explicit playback',
        );
      }
    }
  }

  Future<void> pause() {
    return _enqueuePlaybackRequest(_pauseInternal);
  }

  Future<void> _pauseInternal() async {
    debugPrint('[Playback] pause() called');
    try {
      await _playbackManager.pause();
    } catch (e) {
      debugPrint('Pause failed: $e');
    }
  }

  Future<void> resume() {
    return _enqueuePlaybackRequest(_resumeInternal);
  }

  Future<void> _resumeInternal() async {
    await initAudio();

    final song = currentSongNotifier.value ?? _songAtCurrentIndex();
    if (song == null || song.filePath == null) {
      return;
    }

    debugPrint('[Playback] resume() called');
    final desiredEngine = await _routeManager.resolvePreferredEngineType(
      refresh: true,
    );
    final activeEngine = await _ensureEngineReady(
      desiredEngine,
      reason: 'resume requested',
    );
    debugPrint('[Engine] Resume route resolved to ${activeEngine.name}');

    final latestState = _playbackManager.latestState;
    final canResumeDirectly =
        latestState != null &&
        latestState.engine == activeEngine &&
        latestState.currentTrack?.id == song.id;
    if (canResumeDirectly) {
      await _playbackManager.play();
    } else {
      final resumePosition = positionNotifier.value > Duration.zero
          ? positionNotifier.value
          : _consumeRestoredPositionForSong(song);
      await _prepareImmediatePlaybackAsset(song);
      await _playbackManager.playTrack(song, initialPosition: resumePosition);
    }

    _ensurePositionSaveTimer();
  }

  Future<void> togglePlayPause() {
    return _enqueuePlaybackRequest(() async {
      if (isPlayingNotifier.value) {
        await _pauseInternal();
      } else {
        await _resumeInternal();
      }
    });
  }

  Future<void> seek(Duration position) async {
    try {
      await _playbackManager.seek(position);
    } catch (e) {
      debugPrint('Seek failed: $e');
    }
    unawaited(_updateNotificationState());
  }

  Future<void> next() {
    return _enqueuePlaybackRequest(_nextInternal);
  }

  Future<void> _nextInternal() async {
    if (_playlist.isEmpty) return;

    debugPrint(
      'next(): currentIndex=$_currentIndex, playlistLength=${_playlist.length}, loopMode=${loopModeNotifier.value}',
    );

    if (_currentIndex < _playlist.length - 1) {
      final targetIndex = _currentIndex + 1;
      _setCurrentIndex(targetIndex);
      await _playSongAtCurrentIndex();
      return;
    }

    if (loopModeNotifier.value == LoopMode.all) {
      debugPrint('next(): LoopMode.all, wrapping to index 0');
      _setCurrentIndex(0);
      await _playSongAtCurrentIndex();
      return;
    }

    debugPrint('next(): End of playlist, pausing');
    await pause();
    await seek(Duration.zero);
  }

  Future<void> previous() {
    return _enqueuePlaybackRequest(_previousInternal);
  }

  Future<void> _previousInternal() async {
    if (_playlist.isEmpty) return;

    if (positionNotifier.value.inSeconds > 3) {
      await seek(Duration.zero);
      return;
    }

    if (_currentIndex > 0) {
      final targetIndex = _currentIndex - 1;
      _setCurrentIndex(targetIndex);
      await _playSongAtCurrentIndex();
      return;
    }

    await seek(Duration.zero);
  }

  /// Rebuild the current playlist with updated settings
  Future<void> _rebuildPlaylist() async {
    if (_usingRustBackend) return;
    if (_playlist.isEmpty || _currentIndex < 0) return;

    try {
      _isRebuildingPlaylist = true;
      final player = _justAudioPlayer;
      if (player == null) return;
      final wasPlaying = isPlayingNotifier.value;
      final currentPosition = positionNotifier.value;

      final sources = await _buildAudioSources();

      await _runWithSuppressedSequenceStateUpdates(() async {
        await player.setAudioSources(
          sources,
          initialIndex: _currentIndex,
          preload: true,
        );

        await player.seek(currentPosition, index: _currentIndex);
        await _updateLoopMode();
      });

      if (wasPlaying) {
        await player.play();
      }
    } catch (e) {
      debugPrint('Error rebuilding playlist: $e');
    } finally {
      _isRebuildingPlaylist = false;
    }
  }

  /// Update loop mode based on current loop mode setting
  Future<void> _updateLoopMode() async {
    final player = _justAudioPlayer;
    if (player == null) return;

    switch (loopModeNotifier.value) {
      case LoopMode.off:
        await player.setLoopMode(just_audio.LoopMode.off);
        break;
      case LoopMode.one:
        await player.setLoopMode(just_audio.LoopMode.one);
        break;
      case LoopMode.all:
        await player.setLoopMode(just_audio.LoopMode.all);
        break;
    }
  }

  // ==================== Shuffle/Loop Toggles ====================

  Future<void> toggleShuffle() async {
    final enable = !isShuffleNotifier.value;
    isShuffleNotifier.value = enable;

    final current = currentSongNotifier.value;
    final basePlaylist = <Song>[];
    for (var i = 0; i < _playlist.length; i++) {
      if (_playlistQueueEntryIds[i] == null) {
        basePlaylist.add(_playlist[i]);
      }
    }

    final reorderedBasePlaylist = enable
        ? buildShufflePlaybackOrder(songs: basePlaylist, current: current)
        : restorePlaybackOrder(
            originalPlaylist: _originalPlaylist,
            current: current,
            insertionIndex: _currentIndex,
          );

    _playlist
      ..clear()
      ..addAll(reorderedBasePlaylist);
    _playlistQueueEntryIds
      ..clear()
      ..addAll(List<int?>.filled(reorderedBasePlaylist.length, null));
    if (current != null) {
      _setCurrentIndex(_playlist.indexWhere((song) => song.id == current.id));
    }
    if (_currentIndex < 0 && _playlist.isNotEmpty) {
      _setCurrentIndex(0);
    }
    _insertQueuedEntriesAfterCurrent();

    // Rebuild playlist with new order (just_audio only).
    if (!_usingRustBackend) {
      await _rebuildPlaylist();
    }
    await _updateNotificationState();
  }

  void toggleLoopMode() {
    final modes = LoopMode.values;
    final nextIndex = (loopModeNotifier.value.index + 1) % modes.length;
    loopModeNotifier.value = modes[nextIndex];

    _updateLoopMode();
  }

  // ==================== Volume ====================

  Future<void> setVolume(double volume) async {
    final clampedVolume = volume.clamp(0.0, 1.0).toDouble();
    _currentVolume = clampedVolume;
    if (_usingRustBackend) {
      await _rustAudioService.setVolume(clampedVolume);
    } else {
      final player = _justAudioPlayer;
      if (player != null) {
        await player.setVolume(clampedVolume);
      }
    }
  }

  Future<void> addToQueue(Song song) async {
    final entry = _QueueEntry(id: _nextQueueEntryId++, song: song);
    _queuedEntries.add(entry);
    if (_playlist.isNotEmpty) {
      final insertIndex = (_currentIndex + 1 + _queuedEntries.length - 1).clamp(
        0,
        _playlist.length,
      );
      _playlist.insert(insertIndex, song);
      _playlistQueueEntryIds.insert(insertIndex, entry.id);
    }
    _notifyQueueChanged();

    if (_playlist.isNotEmpty && !_usingRustBackend) {
      await _rebuildPlaylist();
    }
  }

  Future<void> playFromQueueIndex(int index) {
    return _enqueuePlaybackRequest(() => _playFromQueueIndexInternal(index));
  }

  Future<void> _playFromQueueIndexInternal(int index) async {
    if (index < 0 || index >= _queuedEntries.length) return;
    final entry = _queuedEntries.removeAt(index);
    final playlistIndex = _findPlaylistIndexForQueueEntry(entry.id);
    if (playlistIndex != -1) {
      _playlistQueueEntryIds[playlistIndex] = null;
      _notifyQueueChanged();
      _setCurrentIndex(playlistIndex);
      await _playSongAtCurrentIndex();
      return;
    }

    _notifyQueueChanged();
    await play(entry.song);
  }

  Future<void> clearQueue() async {
    if (_queuedEntries.isEmpty) return;
    final queuedIds = _queuedEntries.map((entry) => entry.id).toSet();
    for (var i = _playlistQueueEntryIds.length - 1; i >= 0; i--) {
      final queueId = _playlistQueueEntryIds[i];
      if (queueId != null && queuedIds.contains(queueId)) {
        _playlist.removeAt(i);
        _playlistQueueEntryIds.removeAt(i);
        if (i < _currentIndex) {
          _setCurrentIndex(_currentIndex - 1);
        }
      }
    }
    _queuedEntries.clear();
    _notifyQueueChanged();
    if (!_usingRustBackend) {
      await _rebuildPlaylist();
    }
  }

  Future<void> removeFromQueue(int index) async {
    if (index < 0 || index >= _queuedEntries.length) return;
    final entry = _queuedEntries[index];
    await _removeQueueEntryById(entry.id);
  }

  Future<void> moveQueueItem(int oldIndex, int newIndex) async {
    if (oldIndex < 0 ||
        oldIndex >= _queuedEntries.length ||
        newIndex < 0 ||
        newIndex >= _queuedEntries.length) {
      return;
    }
    if (oldIndex == newIndex) return;

    final entry = _queuedEntries.removeAt(oldIndex);
    _queuedEntries.insert(newIndex, entry);

    for (var i = _playlistQueueEntryIds.length - 1; i >= 0; i--) {
      if (_playlistQueueEntryIds[i] != null) {
        _playlist.removeAt(i);
        _playlistQueueEntryIds.removeAt(i);
      }
    }
    _insertQueuedEntriesAfterCurrent();
    _notifyQueueChanged();
    if (!_usingRustBackend) {
      await _rebuildPlaylist();
    }
  }

  Future<void> moveQueueItemToNext(int index) async {
    if (index <= 0 || index >= _queuedEntries.length) return;
    await moveQueueItem(index, 0);
  }

  // ==================== Playback Speed ====================

  Future<void> setPlaybackSpeed(double speed) async {
    final clampedSpeed = speed.clamp(0.5, 2.0).toDouble();
    playbackSpeedNotifier.value = clampedSpeed;
    if (_usingRustBackend) {
      await _rustAudioService.setPlaybackSpeed(clampedSpeed);
    } else {
      final player = _justAudioPlayer;
      if (player != null) {
        await player.setSpeed(clampedSpeed);
      }
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

  bool _shouldIgnoreAutoSyncedSong(Song song) {
    final guardUntil = _autoSyncGuardUntil;
    final guardedSongId = _autoSyncGuardSongId;
    if (guardUntil == null || guardedSongId == null) {
      return false;
    }

    if (DateTime.now().isAfter(guardUntil)) {
      _clearAutoSyncGuard();
      return false;
    }

    return song.id != guardedSongId;
  }

  void _armAutoSyncGuard(Song song) {
    _autoSyncGuardSongId = song.id;
    _autoSyncGuardUntil = DateTime.now().add(const Duration(seconds: 2));
  }

  void _updateAutoSyncGuardFromProgress(Duration position) {
    if (_autoSyncGuardSongId == null) return;
    if (position > const Duration(milliseconds: 250)) {
      _clearAutoSyncGuard();
    }
  }

  void _clearAutoSyncGuard() {
    _autoSyncGuardSongId = null;
    _autoSyncGuardUntil = null;
  }

  void _ensurePositionSaveTimer() {
    _positionSaveTimer?.cancel();
    _positionSaveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _savePosition(),
    );
  }

  void dispose() {
    _positionSaveTimer?.cancel();
    unawaited(_audioFocusSubscription?.cancel());
    cancelSleepTimer();
    _notificationService.hideNotification();
    if (_usingRustBackend) {
      unawaited(_rustAudioService.stop());
    }

    final player = _justAudioPlayer;
    if (player != null) {
      for (final subscription in _justAudioSubscriptions) {
        unawaited(subscription.cancel());
      }
      _justAudioSubscriptions.clear();
      unawaited(player.dispose());
      _justAudioPlayer = null;
    }
    _playbackStateSubscription?.cancel();
    unawaited(_playbackManager.dispose());
    _routeManager.dispose();

    currentSongNotifier.dispose();
    isPlayingNotifier.dispose();
    positionNotifier.dispose();
    durationNotifier.dispose();
    bufferedPositionNotifier.dispose();
    playbackSpeedNotifier.dispose();
    sleepTimerRemainingNotifier.dispose();

    for (final convertedPath in _convertedPlaybackPathCache.values) {
      unawaited(_deleteTemporaryPlaybackFile(convertedPath));
    }
  }

  Future<T> _runWithSuppressedSequenceStateUpdates<T>(
    Future<T> Function() action,
  ) async {
    final previousValue = _suppressSequenceStateUpdates;
    _suppressSequenceStateUpdates = true;
    try {
      return await action();
    } finally {
      _suppressSequenceStateUpdates = previousValue;
    }
  }

  Future<void> _deleteTemporaryPlaybackFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('Failed to delete temporary playback file: $e');
    }
  }
}

class _QueueEntry {
  final int id;
  final Song song;

  const _QueueEntry({required this.id, required this.song});
}
