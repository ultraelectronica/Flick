import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/models/audio_output_diagnostics.dart';
import 'package:flick/models/playback_state.dart';
import 'package:flick/models/song.dart';
import 'package:flick/src/rust/api/audio_api.dart' as rust_audio;
import 'package:flick/services/notification_service.dart';
import 'package:flick/services/android_audio_engine.dart';
import 'package:flick/services/android_audio_device_service.dart';
import 'package:flick/services/audio_engine_manager.dart';
import 'package:flick/services/audio_session_manager.dart';
import 'package:flick/services/equalizer_service.dart';
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
    _sessionManager = AudioSessionManager(
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
  late final AudioSessionManager _sessionManager;
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
  final ValueNotifier<AudioOutputDiagnostics?> audioOutputDiagnosticsNotifier =
      ValueNotifier(null);
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
    _sessionManager.selectedModeNotifier.addListener(() {
      unawaited(
        _refreshAudioOutputDiagnostics(
          reason: 'selected playback mode changed',
        ),
      );
    });
    _sessionManager.initializedModeNotifier.addListener(() {
      unawaited(
        _refreshAudioOutputDiagnostics(
          reason: 'initialized playback mode changed',
        ),
      );
    });
    AndroidAudioDeviceService.instance.deviceInfoNotifier.addListener(() {
      unawaited(_refreshAudioOutputDiagnostics(reason: 'audio route changed'));
    });
    _uac2Service.bitPerfectEnabledNotifier.addListener(() {
      unawaited(_handleBitPerfectPreferenceChanged());
    });
    _notifyQueueChanged();
  }

  Future<void> _handleBitPerfectPreferenceChanged() async {
    if (isBitPerfectModeEnabled) {
      if (_usingRustBackend && _rustAudioService.isInitialized) {
        await _applyRustPlaybackProcessingPolicy(currentEngineType);
      } else {
        final player = _justAudioPlayer;
        if (player != null) {
          await player.setVolume(1.0);
          await player.setSpeed(1.0);
        }
      }
    } else {
      if (_usingRustBackend && _rustAudioService.isInitialized) {
        await _applyRustPlaybackProcessingPolicy(currentEngineType);
      } else {
        final player = _justAudioPlayer;
        if (player != null) {
          await player.setVolume(_currentVolume);
          await player.setSpeed(playbackSpeedNotifier.value);
        }
      }
    }

    await reapplyEqualizer();
    await _refreshAudioOutputDiagnostics(
      reason: 'bit-perfect preference changed',
    );
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
  ValueNotifier<AudioEngineType> get selectedPlaybackModeNotifier =>
      _sessionManager.selectedModeNotifier;
  ValueNotifier<AudioEngineType?> get initializedPlaybackModeNotifier =>
      _sessionManager.initializedModeNotifier;
  AudioEngineType get currentEngineType =>
      _sessionManager.initializedMode ?? _sessionManager.selectedMode;
  bool get isBitPerfectModeEnabled => _uac2Service.isBitPerfectEnabledSync;
  bool get isBitPerfectProcessingLocked =>
      isBitPerfectModeEnabled ||
      currentEngineType == AudioEngineType.usbDacExperimental;

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

    final future = _prepareForAppLaunchInternal();

    _appLaunchPreparationInFlight = future;
    try {
      await future;
    } finally {
      _appLaunchPreparationInFlight = null;
    }
  }

  Future<void> _prepareForAppLaunchInternal() async {
    await initAudio();

    if (!Platform.isAndroid) {
      return;
    }
    final preferredMode = await _sessionManager.resolvePreferredMode(
      refresh: true,
    );
    if (preferredMode != AudioEngineType.normalAndroid) {
      debugPrint(
        '[Engine] Skipping Android prewarm because ${preferredMode.logLabel} '
        'is preferred for the current route',
      );
      return;
    }
    if (_justAudioPlayer != null) {
      return;
    }

    debugPrint('[Engine] Prewarming Android engine for non-USB route');
    try {
      await _ensureAndroidEngineInitialized();
    } catch (e) {
      debugPrint('[Engine] Android prewarm skipped: $e');
    }
  }

  Future<void> setHiFiModeEnabled(bool enabled) async {
    await initAudio();
    await _sessionManager.setHiFiModeEnabled(enabled);
  }

  Future<bool> isHiFiModeEnabled() async {
    await initAudio();
    return _sessionManager.isHiFiModeEnabled();
  }

  Future<void> _initializeAudio() async {
    debugPrint('[Engine] Initializing audio manager');

    try {
      await Future.wait<void>([
        _sessionManager.initialize(),
        _uac2Service.isBitPerfectEnabled(),
      ]);
      _playbackManager.publishIdleState(_sessionManager.selectedMode);
      _audioInitialized = true;
      await _refreshAudioOutputDiagnostics(reason: 'audio initialized');
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

  Future<void> _deactivateAndroidAudioSession() async {
    if (!Platform.isAndroid || !_audioSessionConfigured) {
      return;
    }

    try {
      final session = await AudioSession.instance;
      await session.setActive(false);
    } catch (e) {
      debugPrint('[AudioFocus] Failed to deactivate Android audio session: $e');
    }
  }

  Future<void> _releaseAndroidManagedAudioResources({
    required String reason,
  }) async {
    if (!Platform.isAndroid) {
      return;
    }

    debugPrint('[Engine] Releasing Android-managed audio resources ($reason)');
    await _disposeAndroidEngine();
    await _deactivateAndroidAudioSession();
  }

  Future<bool> _ensureRustBackendAvailable() async {
    if (_rustBackendAvailable && _rustAudioService.isInitialized) {
      return true;
    }
    if (_rustBackendAvailable && !_rustAudioService.isInitialized) {
      debugPrint(
        '[Engine] Rust backend flag was stale; reinitializing Rust audio manager',
      );
      _rustBackendAvailable = false;
    }
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
      playbackMode: currentEngineType,
    );
    await _refreshAudioOutputDiagnostics(
      reason: 'UAC2 status sync',
      activeSong: song,
    );
  }

  Future<void> _refreshAudioOutputDiagnostics({
    required String reason,
    Song? activeSong,
  }) async {
    final mode = currentEngineType;
    final song = activeSong ?? currentSongNotifier.value;
    final trackFormat = _deriveUac2FormatFromSong(song);
    final deviceInfo = Platform.isAndroid
        ? AndroidAudioDeviceService.instance.deviceInfoNotifier.value
        : AndroidPlaybackDeviceInfo.unknown;
    final debugState = Platform.isAndroid
        ? await _uac2Service.getAndroidPlaybackDebugState()
        : null;
    final rustAudioState = _mapValue(debugState?['rustAudioState']);
    final engineState = _mapValue(rustAudioState?['engine']);
    final directUsbState = _mapValue(rustAudioState?['direct_usb']);

    final outputSignature = _stringValue(
      engineState?['output_signature'] ?? engineState?['outputSignature'],
    );
    final engineConfiguredSampleRate = _intValue(
      engineState?['sample_rate'] ?? engineState?['sampleRate'],
    );
    final directUsbConfiguredSampleRate = _intValue(
      directUsbState?['playback_format_sample_rate'] ??
          directUsbState?['playbackFormatSampleRate'],
    );
    final directUsbClockReportedSampleRate = _intValue(
      directUsbState?['clock_reported_sample_rate'] ??
          directUsbState?['clockReportedSampleRate'],
    );
    final directUsbClockControlSucceeded =
        directUsbState?['clock_control_succeeded'] == true ||
        directUsbState?['clockControlSucceeded'] == true;
    final directUsbClockVerificationPassed =
        directUsbState?['clock_verification_passed'] == true ||
        directUsbState?['clockVerificationPassed'] == true;
    final directUsbDacClockPolicy = _stringValue(
      directUsbState?['dac_clock_policy'] ?? directUsbState?['dacClockPolicy'],
    );
    final directUsbBitPerfectVerified =
        directUsbState?['bit_perfect_verified'] == true ||
        directUsbState?['bitPerfectVerified'] == true;
    final directUsbRegistered =
        debugState?['directUsbRegistered'] == true ||
        directUsbState?['registered'] == true;
    final usbInterfaceClaimed =
        directUsbState?['idle_lock_held'] == true ||
        directUsbState?['stream_active'] == true;
    final usbStreamStable =
        directUsbState?['usb_stream_stable'] == true ||
        directUsbState?['usbStreamStable'] == true;
    final audioFocusHeld = debugState?['audioFocusHeld'] == true;

    final pathManagement = switch (mode) {
      AudioEngineType.usbDacExperimental
          when outputSignature?.startsWith('android-uac2:') == true =>
        AudioPathManagement.directUsbExperimental,
      AudioEngineType.usbDacExperimental ||
      AudioEngineType.dapInternalHighRes =>
        AudioPathManagement.androidManagedLowLatency,
      AudioEngineType.normalAndroid => AudioPathManagement.androidManagedShared,
    };

    final isMixerManaged =
        pathManagement != AudioPathManagement.directUsbExperimental;
    final requestedOutputSampleRate =
        pathManagement == AudioPathManagement.directUsbExperimental
        ? directUsbConfiguredSampleRate
        : mode.usesRustBackend
        ? engineConfiguredSampleRate ?? trackFormat?.sampleRate
        : null;
    final reportedOutputSampleRate =
        pathManagement == AudioPathManagement.directUsbExperimental
        ? directUsbClockReportedSampleRate
        : engineConfiguredSampleRate;
    final backendDescription = switch (pathManagement) {
      AudioPathManagement.directUsbExperimental
          when directUsbClockVerificationPassed =>
        'Rust engine via libusb isochronous transfers (verified DAC rate)',
      AudioPathManagement.directUsbExperimental =>
        'Rust engine via libusb isochronous transfers',
      AudioPathManagement.androidManagedLowLatency =>
        'Rust engine via Oboe/AAudio (Android-managed)',
      AudioPathManagement.androidManagedShared =>
        'Android player via just_audio / ExoPlayer',
    };
    final androidManagedUsbRoute =
        pathManagement != AudioPathManagement.directUsbExperimental &&
        (deviceInfo.hasUsbDac ||
            deviceInfo.hasAttachedUac2Device ||
            deviceInfo.looksLikeUsbAudioRoute);

    final capabilityStateLabel = switch (mode) {
      AudioEngineType.usbDacExperimental
          when pathManagement == AudioPathManagement.directUsbExperimental &&
              directUsbBitPerfectVerified =>
        'Bit-perfect USB (active)',
      AudioEngineType.usbDacExperimental
          when pathManagement == AudioPathManagement.directUsbExperimental =>
        'Exclusive USB (active)',
      AudioEngineType.usbDacExperimental => 'Android (resampled)',
      AudioEngineType.dapInternalHighRes => 'Android high-res',
      AudioEngineType.normalAndroid when androidManagedUsbRoute =>
        'Android (resampled)',
      AudioEngineType.normalAndroid => 'Android',
    };

    final effectiveDirectUsbDacClockPolicy =
        pathManagement == AudioPathManagement.directUsbExperimental
        ? directUsbDacClockPolicy
        : null;
    final effectiveClockOk =
        pathManagement == AudioPathManagement.directUsbExperimental
        ? directUsbClockControlSucceeded
        : true;
    final effectiveRateVerified =
        pathManagement == AudioPathManagement.directUsbExperimental
        ? directUsbClockVerificationPassed
        : true;

    final capabilityFlags = AudioCapabilityFlags(
      supportsExclusiveUsbOwnership:
          pathManagement == AudioPathManagement.directUsbExperimental &&
          directUsbRegistered &&
          usbInterfaceClaimed,
      supportsDirectSampleRateSwitching:
          pathManagement == AudioPathManagement.directUsbExperimental &&
          directUsbClockVerificationPassed,
      supportsVerifiedBitPerfect:
          pathManagement == AudioPathManagement.directUsbExperimental &&
          directUsbBitPerfectVerified,
      supportsAndroidManagedHighResOnly:
          mode == AudioEngineType.dapInternalHighRes,
      supportsInternalDapPathOnly:
          mode == AudioEngineType.dapInternalHighRes && !deviceInfo.hasUsbDac,
    );

    audioOutputDiagnosticsNotifier.value = AudioOutputDiagnostics(
      selectedMode: _sessionManager.selectedMode,
      initializedMode: _sessionManager.initializedMode,
      pathManagement: pathManagement,
      capabilityStateLabel: capabilityStateLabel,
      backendDescription: backendDescription,
      routeType: deviceInfo.routeType ?? 'unknown',
      routeLabel: deviceInfo.routeSummary,
      outputDeviceLabel:
          _stringValue(
            directUsbState?['product_name'] ?? directUsbState?['productName'],
          ) ??
          _uac2Service.currentDeviceStatus?.device.productName ??
          deviceInfo.routeSummary,
      isMixerManaged: isMixerManaged,
      audioFocusHeld: audioFocusHeld,
      directUsbRegistered: directUsbRegistered,
      usbInterfaceClaimed: usbInterfaceClaimed,
      usbStreamStable: usbStreamStable,
      trackSampleRate: trackFormat?.sampleRate,
      requestedOutputSampleRate: requestedOutputSampleRate,
      reportedOutputSampleRate: reportedOutputSampleRate,
      activeOutputSignature: outputSignature,
      fallbackReason: _sessionManager.fallbackReason,
      capabilityFlags: capabilityFlags,
    );

    final activeAltSetting = _intValue(
      directUsbState?['active_alt_setting'] ??
          directUsbState?['activeAltSetting'],
    );
    final activeEndpointAddress = _intValue(
      directUsbState?['active_endpoint_address'] ??
          directUsbState?['activeEndpointAddress'],
    );
    final transportFormat = _stringValue(
      directUsbState?['transport_format'] ?? directUsbState?['transportFormat'],
    );
    final transportSubslot = _intValue(
      directUsbState?['transport_subslot_size'] ??
          directUsbState?['transportSubslotSize'],
    );
    final transportBitResolution = _intValue(
      directUsbState?['transport_bit_resolution'] ??
          directUsbState?['transportBitResolution'],
    );
    final activeSyncType = _stringValue(
      directUsbState?['active_sync_type'] ?? directUsbState?['activeSyncType'],
    );
    final activeUsageType = _stringValue(
      directUsbState?['active_usage_type'] ??
          directUsbState?['activeUsageType'],
    );
    final activeRefresh = _intValue(
      directUsbState?['active_refresh'] ?? directUsbState?['activeRefresh'],
    );
    final activeSynchAddress = _intValue(
      directUsbState?['active_synch_address'] ??
          directUsbState?['activeSynchAddress'],
    );
    final activeServiceIntervalUs = _intValue(
      directUsbState?['active_service_interval_us'] ??
          directUsbState?['activeServiceIntervalUs'],
    );
    final activeMaxPacketBytes = _intValue(
      directUsbState?['active_max_packet_bytes'] ??
          directUsbState?['activeMaxPacketBytes'],
    );
    final directUsbRefusalReason = _stringValue(
      directUsbState?['direct_mode_refusal_reason'] ??
          directUsbState?['directModeRefusalReason'],
    );
    final packetSchedulePreview = _dynamicListValue(
      directUsbState?['packet_schedule_frames_preview'] ??
          directUsbState?['packetScheduleFramesPreview'],
    );
    final bufferFillMs = _intValue(
      directUsbState?['buffer_fill_ms'] ?? directUsbState?['bufferFillMs'],
    );
    final bufferCapacityMs = _intValue(
      directUsbState?['buffer_capacity_ms'] ??
          directUsbState?['bufferCapacityMs'],
    );
    final bufferTargetMs = _intValue(
      directUsbState?['buffer_target_ms'] ?? directUsbState?['bufferTargetMs'],
    );
    final framesPerPacket = _intValue(
      directUsbState?['frames_per_packet'] ??
          directUsbState?['framesPerPacket'],
    );
    final underrunCount = _intValue(
      directUsbState?['underrun_count'] ?? directUsbState?['underrunCount'],
    );
    final producerFrames = _intValue(
      directUsbState?['producer_frames'] ?? directUsbState?['producerFrames'],
    );
    final consumerFrames = _intValue(
      directUsbState?['consumer_frames'] ?? directUsbState?['consumerFrames'],
    );
    final driftMsFromTarget = _intValue(
      directUsbState?['drift_ms_from_target'] ??
          directUsbState?['driftMsFromTarget'],
    );
    final directUsbLastError = _stringValue(
      directUsbState?['last_error'] ?? directUsbState?['lastError'],
    );

    debugPrint(
      '[Diagnostics] $reason: mode=${mode.logLabel}, '
      'selected=${_sessionManager.selectedMode.logLabel}, '
      'path=$pathManagement, route=${deviceInfo.routeSummary}, '
      'backend="$backendDescription", requested=$requestedOutputSampleRate, '
      'reported=$reportedOutputSampleRate, focus=$audioFocusHeld, '
      'usbRegistered=$directUsbRegistered, usbClaimed=$usbInterfaceClaimed, '
      'usbStreamStable=$usbStreamStable, '
      'mixerManaged=$isMixerManaged, signature=${outputSignature ?? 'none'}, '
      'alt=${activeAltSetting ?? -1}, endpoint=${activeEndpointAddress ?? -1}, '
      'sync=${activeSyncType ?? 'none'}, usage=${activeUsageType ?? 'none'}, '
      'refresh=${activeRefresh ?? -1}, synchAddress=${activeSynchAddress ?? -1}, '
      'clockOk=$effectiveClockOk, rateVerified=$effectiveRateVerified, '
      'dacPolicy=${effectiveDirectUsbDacClockPolicy ?? 'none'}, '
      'bitPerfect=$directUsbBitPerfectVerified, '
      'serviceUs=${activeServiceIntervalUs ?? -1}, maxPacket=${activeMaxPacketBytes ?? -1}, '
      'schedule=${packetSchedulePreview ?? const []}, '
      'bufferMs=${bufferFillMs ?? -1}/${bufferTargetMs ?? -1}/${bufferCapacityMs ?? -1}, '
      'framesPerPacket=${framesPerPacket ?? -1}, underruns=${underrunCount ?? -1}, '
      'producerFrames=${producerFrames ?? -1}, consumerFrames=${consumerFrames ?? -1}, '
      'driftMs=${driftMsFromTarget ?? -999}, '
      'transport=${transportFormat ?? 'none'}/${transportBitResolution ?? -1}/'
      '${transportSubslot ?? -1}, refusal=${directUsbRefusalReason ?? 'none'}, '
      'lastError=${directUsbLastError ?? 'none'}, '
      'fallback=${_sessionManager.fallbackReason ?? 'none'}',
    );
  }

  Map<String, dynamic>? _mapValue(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  }

  String? _stringValue(dynamic value) {
    return value is String && value.isNotEmpty ? value : null;
  }

  int? _intValue(dynamic value) {
    return value is num ? value.toInt() : null;
  }

  List<int>? _dynamicListValue(dynamic value) {
    if (value is List) {
      return value.whereType<num>().map((entry) => entry.toInt()).toList();
    }
    return null;
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
        if (_suppressSequenceStateUpdates) {
          return;
        }
        final activeIndex = player.currentIndex;
        if (activeIndex != null && activeIndex != _currentIndex) {
          _syncCurrentSongFromIndex(activeIndex, fromListener: true);
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
    _rustAudioService.onError = (message) {
      debugPrint('[PlayerService] Rust backend error: $message');
      unawaited(_refreshAudioOutputDiagnostics(reason: 'Rust backend error'));
    };
  }

  void _bindPlaybackState() {
    _playbackStateSubscription?.cancel();
    _playbackStateSubscription = _playbackManager.playbackState.listen((state) {
      final previous = _lastPlaybackState;
      _lastPlaybackState = state;

      // When the engine attaches or reinitialises it briefly emits a null-track
      // transitional state before the real track loads. If the playlist is still
      // populated (songs are queued) we preserve the last known song in the
      // notifier so the mini-player and ambient background never flash to black.
      // We only truly clear the song notifier when the playlist itself is empty
      // (i.e. the user explicitly stopped all playback).
      final incomingTrack =
          state.currentTrack ??
          (_playlist.isNotEmpty ? currentSongNotifier.value : null);
      if (currentSongNotifier.value != incomingTrack) {
        currentSongNotifier.value = incomingTrack;
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

      final shouldUseRust = state.engine.usesRustBackend;
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

      unawaited(
        _refreshAudioOutputDiagnostics(
          reason: 'playback state changed',
          activeSong: state.currentTrack,
        ),
      );
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
    await _refreshAudioOutputDiagnostics(reason: 'playback stopped');
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
    await reapplyEqualizer();
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

  RustAudioEngine _createRustEngine(AudioEngineType playbackMode) {
    return RustAudioEngine(
      playbackMode: playbackMode,
      rustAudioService: _rustAudioService,
      ensureInitialized: () => _ensureRustEngineInitialized(playbackMode),
      resolvePlaybackPath: _resolveRustPath,
      disposeEngine: _disposeUsbEngine,
    );
  }

  Future<void> _ensureRustEngineInitialized(
    AudioEngineType playbackMode,
  ) async {
    final requiresUsbDac =
        playbackMode == AudioEngineType.usbDacExperimental &&
        Platform.isAndroid;
    if (requiresUsbDac) {
      final deviceInfo = await AndroidAudioDeviceService.instance.refresh();
      if (!deviceInfo.hasUsbDac) {
        debugPrint('[Engine] USB init blocked: no USB DAC detected');
        throw StateError('Rust USB engine requires a USB DAC');
      }
    }

    if (!_rustAudioService.isInitialized) {
      debugPrint(
        '[Engine] Initializing Rust engine for ${playbackMode.logLabel}',
      );
    }

    final rustAvailable = await _ensureRustBackendAvailable();
    if (!rustAvailable) {
      throw StateError(
        'Rust audio engine is unavailable for ${playbackMode.logLabel}',
      );
    }

    if (Platform.isAndroid) {
      await _rustAudioService.setHighResMode(
        playbackMode == AudioEngineType.dapInternalHighRes,
      );
      await _uac2Service.initialize();
      await _refreshRustCapabilityInfo();

      Uac2AudioFormat? directUsbFormat;
      int? preferredSampleRate;
      if (playbackMode == AudioEngineType.usbDacExperimental) {
        // CRITICAL: Ensure DAC is registered BEFORE calling prepareEngine
        // This fixes the race condition where the engine checks DAC state
        // before the DAC has been registered via JNI
        debugPrint('[Engine] Ensuring USB DAC is registered before engine preparation');
        final dacRegistered = await _ensureUsbDacRegistered();
        if (!dacRegistered) {
          debugPrint('[Engine] Failed to register USB DAC before engine preparation');
          throw StateError('USB DAC registration failed');
        }
        
        directUsbFormat =
            _uac2Service.currentDeviceStatus?.currentFormat ??
            _uac2Service.lastKnownFormat;
        preferredSampleRate = directUsbFormat?.sampleRate;
      }

      try {
        await _rustAudioService.prepareEngine(
          preferredSampleRate: preferredSampleRate,
        );
      } catch (error) {
        final recovered =
            playbackMode == AudioEngineType.usbDacExperimental &&
            directUsbFormat != null &&
            await _retryAndroidDirectUsbPreparationWithFallbackRate(
              initialError: error,
              currentFormat: directUsbFormat,
            );
        if (!recovered) {
          rethrow;
        }
      }

      await _applyRustPlaybackProcessingPolicy(playbackMode);
    }

    _setupRustAudioListeners();
  }

  /// Ensures USB DAC is registered with Rust before engine preparation.
  /// This fixes the race condition where prepareEngine checks DAC state
  /// before the DAC has been registered via JNI.
  Future<bool> _ensureUsbDacRegistered() async {
    try {
      // Check if already registered
      final diagnostics = await _uac2Service.getAndroidPlaybackDebugState();
      final directUsbState = _mapValue(
        _mapValue(diagnostics?['rustAudioState'])?['direct_usb'],
      );
      final alreadyRegistered = directUsbState?['registered'] == true;
      final hasPlaybackFormat = directUsbState?['playback_format_sample_rate'] != null;
      
      if (alreadyRegistered && hasPlaybackFormat) {
        debugPrint('[Engine] USB DAC already registered with playback format');
        return true;
      }

      debugPrint('[Engine] Preparing USB DAC for playback (registered=$alreadyRegistered, hasFormat=$hasPlaybackFormat)');

      // Use prepareAndroidExperimentalUsbPlayback which handles device selection,
      // registration, and format setting all in one
      // Try 48000 Hz first as it's more commonly supported than 44100 Hz
      final format = _uac2Service.currentDeviceStatus?.currentFormat ??
          Uac2AudioFormat(sampleRate: 48000, bitDepth: 16, channels: 2);
      
      final prepared = await _uac2Service.prepareAndroidExperimentalUsbPlayback(
        format: format,
      );

      if (!prepared) {
        debugPrint('[Engine] Failed to prepare USB DAC for playback');
        return false;
      }

      // Verify registration and format are set
      final verifyDiagnostics = await _uac2Service.getAndroidPlaybackDebugState();
      final verifyDirectUsbState = _mapValue(
        _mapValue(verifyDiagnostics?['rustAudioState'])?['direct_usb'],
      );
      final nowRegistered = verifyDirectUsbState?['registered'] == true;
      final nowHasFormat = verifyDirectUsbState?['playback_format_sample_rate'] != null;
      
      if (nowRegistered && nowHasFormat) {
        debugPrint('[Engine] USB DAC successfully prepared: registered=$nowRegistered, hasFormat=$nowHasFormat, rate=${verifyDirectUsbState?['playback_format_sample_rate']}');
      } else {
        debugPrint('[Engine] USB DAC preparation incomplete: registered=$nowRegistered, hasFormat=$nowHasFormat');
      }
      
      return nowRegistered && nowHasFormat;
    } catch (e) {
      debugPrint('[Engine] Error ensuring USB DAC registration: $e');
      return false;
    }
  }

  Future<void> _applyRustPlaybackProcessingPolicy(
    AudioEngineType playbackMode,
  ) async {
    if (!_rustAudioService.isInitialized) {
      return;
    }

    if (isBitPerfectProcessingLocked ||
        playbackMode == AudioEngineType.usbDacExperimental) {
      final needsBypassLog =
          (_currentVolume - 1.0).abs() > 0.0001 ||
          (playbackSpeedNotifier.value - 1.0).abs() > 0.0001 ||
          _rustAudioService.crossfadeEnabledNotifier.value;
      if (needsBypassLog) {
        debugPrint(
          '[Engine] Bit-perfect USB bypassing software volume, playback speed, and crossfade',
        );
      }
      await _rustAudioService.setVolume(1.0);
      await _rustAudioService.setPlaybackSpeed(1.0);
      await _rustAudioService.setCrossfade(
        enabled: false,
        durationSecs: _rustAudioService.crossfadeDurationNotifier.value,
      );
    } else {
      await _rustAudioService.setVolume(_currentVolume);
      await _rustAudioService.setPlaybackSpeed(playbackSpeedNotifier.value);
      await _rustAudioService.setCrossfade(
        enabled: _rustAudioService.crossfadeEnabledNotifier.value,
        durationSecs: _rustAudioService.crossfadeDurationNotifier.value,
      );
    }

    await reapplyEqualizer();
  }

  Future<bool> _retryAndroidDirectUsbPreparationWithFallbackRate({
    required Object initialError,
    required Uac2AudioFormat currentFormat,
  }) async {
    if (!_isDirectUsbClockSetupFailure(initialError.toString())) {
      return false;
    }
    if (await _uac2Service.isBitPerfectEnabled()) {
      debugPrint(
        '[Engine] Bit-perfect USB requires an exact verified DAC rate; '
        'skipping fallback-rate direct retry from '
        '${currentFormat.sampleRate} Hz',
      );
      return false;
    }

    final fallbackFormat = await _uac2Service
        .suggestAndroidExperimentalUsbOutputFormat(
          requested: currentFormat,
          disallowedSampleRates: <int>{currentFormat.sampleRate},
        );
    if (fallbackFormat == null ||
        fallbackFormat.sampleRate == currentFormat.sampleRate) {
      return false;
    }

    debugPrint(
      '[Engine] Direct USB clock setup failed at ${currentFormat.sampleRate} Hz; '
      'retrying direct USB at ${fallbackFormat.sampleRate} Hz',
    );

    final reset = await _uac2Service.resetAndroidDirectUsbPath(
      format: fallbackFormat,
    );
    if (!reset) {
      return false;
    }

    await _refreshRustCapabilityInfo();
    await _rustAudioService.prepareEngine(
      preferredSampleRate: fallbackFormat.sampleRate,
    );
    return true;
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
    await _deactivateAndroidAudioSession();
    _justAudioPlayer = null;
  }

  Future<void> _disposeUsbEngine() async {
    if (!_rustAudioService.isInitialized) return;

    debugPrint('[Engine] Disposing Rust engine');
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

    _rustBackendAvailable = false;
    _rustEngine = null;

    if (Platform.isAndroid) {
      await _rustAudioService.setHighResMode(false);
    }
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
      await _refreshAudioOutputDiagnostics(reason: 'engine detached');
      return;
    }

    if (to == AudioEngineType.usbDacExperimental) {
      await _releaseAndroidManagedAudioResources(
        reason: 'switching to USB_DAC_EXPERIMENTAL',
      );
      await _uac2Service.releaseAndroidDirectUsbRuntime();
    }

    if (to == AudioEngineType.normalAndroid && _rustEngine != null) {
      debugPrint('[Engine] Disposing Rust engine before NORMAL_ANDROID');
      await _disposeUsbEngine();
    }

    final hasDetachedAndroidPrewarm =
        !_playbackManager.hasAttachedEngine && _justAudioPlayer != null;
    if (to != AudioEngineType.normalAndroid && hasDetachedAndroidPrewarm) {
      debugPrint(
        '[Engine] Disposing detached Android prewarm before ${to.logLabel}',
      );
      await _disposeAndroidEngine();
    }

    await _playbackManager.ensureEngine(
      engineType: to,
      createEngine: () async {
        switch (to) {
          case AudioEngineType.normalAndroid:
            _androidEngine = _createAndroidEngine();
            return _androidEngine!;
          case AudioEngineType.usbDacExperimental:
          case AudioEngineType.dapInternalHighRes:
            _rustEngine = _createRustEngine(to);
            return _rustEngine!;
        }
      },
    );
    _usingRustBackend = to.usesRustBackend;
    if (_usingRustBackend) {
      await _rustAudioService.setVolume(_currentVolume);
    }

    debugPrint(
      '[Engine] Switch complete: ${from?.logLabel ?? 'none'} -> '
      '${to.logLabel} ($reason)',
    );
    await _refreshAudioOutputDiagnostics(reason: 'engine switch complete');
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
    if (desiredEngine != AudioEngineType.usbDacExperimental ||
        !Platform.isAndroid) {
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
    return AudioEngineType.normalAndroid;
  }

  Future<AudioEngineType> _ensureEngineReady(
    AudioEngineType desiredEngine, {
    required Song song,
    required String reason,
  }) async {
    final preparedEngine = await _prepareRequestedEngineForSong(
      desiredEngine,
      song: song,
      reason: reason,
    );
    await _sessionManager.switchMode(
      preparedEngine,
      initializeNewEngine: true,
      reason: reason,
    );
    return preparedEngine;
  }

  Future<AudioEngineType> _prepareRequestedEngineForSong(
    AudioEngineType desiredEngine, {
    required Song song,
    required String reason,
  }) async {
    final normalizedEngine = await _normalizeRequestedEngine(
      desiredEngine,
      reason: reason,
    );

    if (!Platform.isAndroid) {
      _sessionManager.clearFallbackReason();
      return normalizedEngine;
    }

    switch (normalizedEngine) {
      case AudioEngineType.normalAndroid:
        await _uac2Service.releaseAndroidDirectUsbRuntime();
        await _rustAudioService.setHighResMode(false);
        _sessionManager.clearFallbackReason();
        return normalizedEngine;
      case AudioEngineType.dapInternalHighRes:
        await _uac2Service.releaseAndroidDirectUsbRuntime();
        await _rustAudioService.setHighResMode(true);
        _sessionManager.clearFallbackReason();
        return normalizedEngine;
      case AudioEngineType.usbDacExperimental:
        await _releaseAndroidManagedAudioResources(
          reason: 'before direct USB initialization',
        );
        final trackFormat = _deriveUac2FormatFromSong(song);
        if (trackFormat == null) {
          await _uac2Service.markAndroidDirectUsbFallback(
            'track sample rate is unavailable before USB engine startup',
          );
          await _uac2Service.releaseAndroidDirectUsbRuntime();
          await _rustAudioService.setHighResMode(false);
          await _sessionManager.recordFallback(
            requestedMode: normalizedEngine,
            fallbackMode: AudioEngineType.normalAndroid,
            reason:
                'track sample rate is unavailable before USB engine startup',
          );
          return AudioEngineType.normalAndroid;
        }

        final prepared = await _uac2Service
            .prepareAndroidExperimentalUsbPlayback(format: trackFormat);
        if (!prepared) {
          await _uac2Service.markAndroidDirectUsbFallback(
            'experimental direct USB path could not be prepared',
          );
          await _uac2Service.releaseAndroidDirectUsbRuntime();
          await _rustAudioService.setHighResMode(false);
          await _sessionManager.recordFallback(
            requestedMode: normalizedEngine,
            fallbackMode: AudioEngineType.normalAndroid,
            reason: 'experimental direct USB path could not be prepared',
          );
          return AudioEngineType.normalAndroid;
        }

        await _rustAudioService.setHighResMode(false);
        _sessionManager.clearFallbackReason();
        return normalizedEngine;
    }
  }

  /// Play a specific song.
  Future<void> play(Song song, {List<Song>? playlist}) {
    debugPrint('[UI] tap(${song.id})');
    return _enqueuePlaybackRequest(
      () => _playInternal(song, playlist: playlist),
    );
  }

  Future<void> _enqueuePlaybackRequest(Future<void> Function() action) {
    debugPrint('[PlayerService] _enqueuePlaybackRequest called');
    final operation = _playRequestQueue
        .then<void>((_) async {
          debugPrint(
            '[PlayerService] _enqueuePlaybackRequest: previous operation complete, executing action',
          );
          try {
            await action();
          } catch (e, stack) {
            debugPrint(
              '[PlayerService] _enqueuePlaybackRequest action error: $e\n$stack',
            );
            rethrow;
          }
        })
        .catchError((e) {
          debugPrint('[PlayerService] _enqueuePlaybackRequest queue error: $e');
        });
    _playRequestQueue = operation;
    return operation;
  }

  Future<void> _playInternal(Song song, {List<Song>? playlist}) async {
    await initAudio();
    try {
      debugPrint(
        '[Playback] play() called for ${song.title} '
        '(selected mode: ${_sessionManager.selectedMode.logLabel})',
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
        // Route changes are already pushed into the session manager via the
        // device listener initialized in initAudio(). Re-querying the platform
        // here adds latency to the first tap on stable speaker routes.
        final desiredEngine = _sessionManager.selectedMode;
        final activeEngine = await _ensureEngineReady(
          desiredEngine,
          song: song,
          reason: 'playback requested',
        );
        debugPrint(
          '[Engine] Playback route resolved to ${activeEngine.logLabel}',
        );
        await _runWithSuppressedSequenceStateUpdates(() async {
          await _playbackManager.playTrack(song);
        });
        _ensurePositionSaveTimer();
        await _refreshAudioOutputDiagnostics(
          reason: 'playback started',
          activeSong: song,
        );
      }
    } catch (e, stackTrace) {
      final recovered = await _handleDirectUsbStartupRefusal(
        e,
        song: song,
        initialPosition: Duration.zero,
      );
      if (recovered) {
        return;
      }
      debugPrint(
        '[Playback] play() failed for ${song.title} '
        'on ${currentEngineType.logLabel}: $e',
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
      _publishRestoredPlaybackState(
        restoredSong,
        position: lastPlayed.position,
      );

      if (restoredSong.filePath != null) {
        debugPrint(
          '[Playback] Restored ${restoredSong.title} at '
          '${lastPlayed.position.inMilliseconds}ms; waiting for explicit playback',
        );
      }
    }
  }

  Future<void> pause() {
    debugPrint('[PlayerService] pause() called');
    return _enqueuePlaybackRequest(_pauseInternal);
  }

  Future<void> _pauseInternal() async {
    debugPrint(
      '[Playback] pause() called, hasAttachedEngine=${_playbackManager.hasAttachedEngine}',
    );
    // Optimistically update UI immediately so the pause button feels responsive.
    if (isPlayingNotifier.value) {
      isPlayingNotifier.value = false;
    }
    // If no engine has been attached yet (e.g. pausing a restored-but-not-started
    // track), there is nothing to pause — the optimistic update above is enough.
    if (!_playbackManager.hasAttachedEngine) {
      debugPrint(
        '[Playback] pause(): no engine attached, returning after optimistic update',
      );
      return;
    }
    try {
      await _playbackManager.pause();
    } catch (e) {
      debugPrint('Pause failed: $e');
    }
    await _refreshAudioOutputDiagnostics(
      reason: 'playback paused',
      activeSong: currentSongNotifier.value,
    );
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
    // Use the cached route selection maintained by the session manager's device
    // listener rather than doing another blocking device probe on resume.
    final desiredEngine = _sessionManager.selectedMode;
    final activeEngine = await _ensureEngineReady(
      desiredEngine,
      song: song,
      reason: 'resume requested',
    );
    debugPrint('[Engine] Resume route resolved to ${activeEngine.logLabel}');

    final latestState = _playbackManager.latestState;
    final canResumeDirectly =
        _playbackManager.canResumeCurrentTrack &&
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
      await _runWithSuppressedSequenceStateUpdates(() async {
        await _playbackManager.playTrack(song, initialPosition: resumePosition);
      });
    }

    _ensurePositionSaveTimer();
    await _refreshAudioOutputDiagnostics(
      reason: 'playback resumed',
      activeSong: song,
    );
  }

  bool _isDirectUsbStartupRefusal(String message) {
    final normalized = message.toLowerCase();
    return message.contains('Requested ') ||
        message.contains('No isochronous OUT endpoint can carry') ||
        message.contains('requires explicit feedback endpoint') ||
        message.contains('cannot be verified') ||
        message.contains('requires PCM transport') ||
        message.contains('requires at least') ||
        message.contains('transport, got') ||
        normalized.contains('android direct usb') ||
        normalized.contains('direct usb backend') ||
        normalized.contains('no android direct usb') ||
        normalized.contains('isochronous transfer') ||
        normalized.contains('failed to set usb clock') ||
        normalized.contains('failed to set usb alt setting') ||
        normalized.contains('requires verified dac rate') ||
        normalized.contains('is not supported by clock') ||
        normalized.contains('usb dac disconnected');
  }

  bool _isDirectUsbClockSetupFailure(String message) {
    final normalized = message.toLowerCase();
    return normalized.contains('failed to set usb clock') ||
        normalized.contains('requires verified dac rate') ||
        normalized.contains('cannot be verified') ||
        normalized.contains('is not supported by clock') ||
        normalized.contains('dac reports');
  }

  bool _isExclusiveUsbUnavailableFailure(String message) {
    final normalized = message.toLowerCase();
    return normalized.contains('input/output error') ||
        normalized.contains('device or resource busy') ||
        normalized.contains('resource busy') ||
        normalized.contains('access denied') ||
        normalized.contains('permission denied');
  }

  Future<bool> _handleDirectUsbStartupRefusal(
    Object error, {
    required Song? song,
    required Duration initialPosition,
  }) async {
    if (!Platform.isAndroid ||
        currentEngineType != AudioEngineType.usbDacExperimental) {
      return false;
    }

    final message = error.toString();
    if (!_isDirectUsbStartupRefusal(message)) {
      return false;
    }

    debugPrint(
      '[Engine] Direct USB startup refused: $message. Falling back to NORMAL_ANDROID',
    );
    await _uac2Service.markAndroidDirectUsbFallback(message);
    await _uac2Service.releaseAndroidDirectUsbRuntime();
    await _rustAudioService.setHighResMode(false);
    if (_isExclusiveUsbUnavailableFailure(message)) {
      await _sessionManager.suppressExperimentalUsbForCurrentDevice(
        reason: message,
      );
    }
    await _sessionManager.recordFallback(
      requestedMode: AudioEngineType.usbDacExperimental,
      fallbackMode: AudioEngineType.normalAndroid,
      reason: message,
    );
    await _sessionManager.switchMode(
      AudioEngineType.normalAndroid,
      initializeNewEngine: true,
      reason: 'direct USB startup refused',
    );

    if (song != null) {
      await _prepareImmediatePlaybackAsset(song);
      await _runWithSuppressedSequenceStateUpdates(() async {
        await _playbackManager.playTrack(
          song,
          initialPosition: initialPosition,
        );
      });
      _ensurePositionSaveTimer();
      await _refreshAudioOutputDiagnostics(
        reason: 'direct USB fallback resumed',
        activeSong: song,
      );
    }

    return true;
  }

  Future<void> togglePlayPause() {
    debugPrint(
      '[PlayerService] togglePlayPause called, isPlaying=${isPlayingNotifier.value}',
    );
    return _enqueuePlaybackRequest(() async {
      debugPrint(
        '[PlayerService] togglePlayPause executing, isPlaying=${isPlayingNotifier.value}',
      );
      try {
        if (isPlayingNotifier.value) {
          await _pauseInternal();
        } else {
          await _resumeInternal();
        }
      } catch (e, stack) {
        final recovered = await _handleDirectUsbStartupRefusal(
          e,
          song: currentSongNotifier.value,
          initialPosition: positionNotifier.value,
        );
        if (recovered) {
          return;
        }
        debugPrint('[PlayerService] togglePlayPause error: $e\n$stack');
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
    debugPrint('[PlayerService] next() called');
    return _enqueuePlaybackRequest(_nextInternal);
  }

  Future<void> _nextInternal() async {
    debugPrint(
      '[PlayerService] _nextInternal() called, playlist.length=${_playlist.length}, currentIndex=$_currentIndex',
    );
    if (_playlist.isEmpty) {
      debugPrint(
        '[PlayerService] _nextInternal: playlist is empty, returning early',
      );
      return;
    }

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
    await _pauseInternal();
    await seek(Duration.zero);
  }

  Future<void> previous() {
    debugPrint('[PlayerService] previous() called');
    return _enqueuePlaybackRequest(_previousInternal);
  }

  Future<void> _previousInternal() async {
    debugPrint(
      '[PlayerService] _previousInternal() called, playlist.length=${_playlist.length}, currentIndex=$_currentIndex',
    );
    if (_playlist.isEmpty) {
      debugPrint(
        '[PlayerService] _previousInternal: playlist is empty, returning early',
      );
      return;
    }

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
    if (isBitPerfectProcessingLocked) {
      debugPrint(
        '[Playback] Ignoring software volume change while Bit-perfect USB is enabled',
      );
      if (_usingRustBackend) {
        await _rustAudioService.setVolume(1.0);
      } else {
        final player = _justAudioPlayer;
        if (player != null) {
          await player.setVolume(1.0);
        }
      }
      return;
    }
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
    await _playInternal(entry.song);
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
    if (isBitPerfectProcessingLocked) {
      debugPrint(
        '[Playback] Ignoring playback-speed change while Bit-perfect USB is enabled',
      );
      if (_usingRustBackend) {
        await _rustAudioService.setPlaybackSpeed(1.0);
      } else {
        final player = _justAudioPlayer;
        if (player != null) {
          await player.setSpeed(1.0);
        }
      }
      return;
    }
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

  void _publishRestoredPlaybackState(Song song, {required Duration position}) {
    if (currentSongNotifier.value != song) {
      currentSongNotifier.value = song;
    }
    if (isPlayingNotifier.value) {
      isPlayingNotifier.value = false;
    }
    if (positionNotifier.value != position) {
      positionNotifier.value = position;
    }
    if (bufferedPositionNotifier.value != Duration.zero) {
      bufferedPositionNotifier.value = Duration.zero;
    }
    if (durationNotifier.value != song.duration) {
      durationNotifier.value = song.duration;
    }
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
    _sessionManager.dispose();
    audioOutputDiagnosticsNotifier.dispose();

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
