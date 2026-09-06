import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:flick/models/advance_list_order.dart';
import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/models/audio_output_diagnostics.dart';
import 'package:flick/models/playback_context.dart';
import 'package:flick/models/playback_state.dart';
import 'package:flick/models/shuffle_mode.dart';
import 'package:flick/models/song.dart';
import 'package:flick/src/rust/api/audio_api.dart' as rust_audio;
import 'package:flick/services/notification_service.dart';
import 'package:flick/services/floating_player_service.dart';
import 'package:flick/services/android_audio_device_service.dart';
import 'package:flick/services/bluetooth_service.dart';
import 'package:flick/services/audio_engine_manager.dart';
import 'package:flick/services/audio_session_manager.dart';
import 'package:flick/services/equalizer_service.dart';
import 'package:flick/services/android_audio_processing_service.dart';
import 'package:flick/services/last_played_service.dart';
import 'package:flick/services/favorites_service.dart';
import 'package:flick/services/replaygain_service.dart';
import 'package:flick/data/repositories/recently_played_repository.dart';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/services/playlist_service.dart';
import 'package:flick/services/replay_play_tracker.dart';
import 'package:flick/services/milestone_service.dart';
import 'package:flick/services/android_audio_engine.dart';
import 'package:flick/services/rust_audio_engine.dart';
import 'package:flick/services/rust_audio_service.dart';
import 'package:flick/services/app_preferences_service.dart';
import 'package:flick/services/uac2_preferences_service.dart';
import 'package:flick/services/color_extraction_service.dart';
import 'package:flick/services/album_color_mode_preference_service.dart';
import 'package:flick/models/album_color_mode.dart';
import 'package:flick/services/uac2_service.dart';
import 'package:flick/services/alac_converter_service.dart';
import 'package:flick/services/remote_source_service.dart';
import 'package:flick/services/casting/casting_service.dart';
import 'package:flick/core/utils/dev_log.dart';

/// Volume Control State Machine:
///
/// Tier evaluation: [determineVolumeTier] — for the direct USB / DAP
/// bit-perfect paths it trusts `Uac2DeviceStatus.volumeMode` (computed
/// natively from `nativeHasRustDirectUsbHardwareVolume()`), the single
/// authoritative source. [PlayerService] feeds it a lie-detector flag
/// (`hwVolumeFailed`) when a DAC that claimed hardware volume rejects
/// writes / fails the GET_CUR health check.
///
/// Reconciliation: [PlayerService._reconcileVolumeForTier]
enum VolumeTier { hardware, software, system, unavailable }

/// Pure tier decision for [PlayerService._determineCurrentTier].
///
/// - Outside the bit-perfect volume path: Rust → software, else system.
/// - DoP: only DAC hardware volume (or the opt-in PCM-decimation switch)
///   can change level — software gain corrupts DoP markers.
/// - Hardware mode trusted → hardware tier.
/// - Otherwise engine gain only works on the DSP path; bit-perfect
///   passthrough must never be scaled → unavailable.
VolumeTier determineVolumeTier({
  required bool isBitPerfectVolumePath,
  required Uac2VolumeMode? volumeMode,
  required bool hwVolumeFailed,
  required bool isDoP,
  required bool autoSwitchDsdForVolume,
  required bool isPassthrough,
  required bool usingRustBackend,
}) {
  if (!isBitPerfectVolumePath) {
    return usingRustBackend ? VolumeTier.software : VolumeTier.system;
  }
  final hwTrusted = volumeMode == Uac2VolumeMode.hardware && !hwVolumeFailed;
  if (isDoP) {
    if (hwTrusted) return VolumeTier.hardware;
    return autoSwitchDsdForVolume
        ? VolumeTier.software
        : VolumeTier.unavailable;
  }
  if (hwTrusted) return VolumeTier.hardware;
  return isPassthrough ? VolumeTier.unavailable : VolumeTier.software;
}

/// Loop mode for playback
enum LoopMode {
  off,
  one,
  all,
  advanceAlbum,
  advanceArtist,
  advanceFolder,
  advancePlaylist,
  stopAfterCurrent;

  bool get isAdvanceMode => switch (this) {
    LoopMode.advanceAlbum ||
    LoopMode.advanceArtist ||
    LoopMode.advanceFolder ||
    LoopMode.advancePlaylist => true,
    _ => false,
  };

  String get label => switch (this) {
    LoopMode.off => 'Off',
    LoopMode.one => 'Repeat One',
    LoopMode.all => 'Repeat All',
    LoopMode.advanceAlbum => 'Advance Album',
    LoopMode.advanceArtist => 'Advance Artist',
    LoopMode.advanceFolder => 'Advance Folder',
    LoopMode.advancePlaylist => 'Advance Playlist',
    LoopMode.stopAfterCurrent => 'Stop After Current',
  };

  String get description => switch (this) {
    LoopMode.off => 'Play list once, stop at end',
    LoopMode.one => 'Repeat current track',
    LoopMode.all => 'Repeat entire list',
    LoopMode.advanceAlbum => 'Play next album when done',
    LoopMode.advanceArtist => 'Play next artist when done',
    LoopMode.advanceFolder => 'Play next folder when done',
    LoopMode.advancePlaylist => 'Play next playlist when done',
    LoopMode.stopAfterCurrent => 'Stop after current song finishes',
  };
}

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

  return loopMode == LoopMode.off ||
      loopMode.isAdvanceMode ||
      loopMode == LoopMode.stopAfterCurrent;
}

@visibleForTesting
bool shouldSyncNotificationForRepeatOneLoop({
  required LoopMode loopMode,
  required bool sameTrack,
  required Duration previousPosition,
  required Duration currentPosition,
  required Duration trackDuration,
}) {
  if (loopMode != LoopMode.one ||
      !sameTrack ||
      trackDuration <= Duration.zero) {
    return false;
  }

  return currentPosition < previousPosition &&
      previousPosition >= trackDuration - const Duration(seconds: 3) &&
      currentPosition <= const Duration(milliseconds: 1500);
}

@visibleForTesting
bool shouldTrackReplayFromPlaybackState({
  required bool usingRustBackend,
  required Duration? previousPosition,
  required Duration currentPosition,
}) {
  if (usingRustBackend) {
    return false;
  }

  return previousPosition == null || previousPosition != currentPosition;
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
  // Cached crossfade curve index (0..3) for synchronous reads inside the
  // just_audio engine's config provider; refreshed from prefs on load/change.
  int _crossfadeCurveIndex = 0;

  final NotificationService _notificationService = NotificationService();
  final FloatingPlayerService _floatingPlayerService = FloatingPlayerService();
  bool _floatingPlayerActive = false;
  bool _appInForeground = true;
  final LastPlayedService _lastPlayedService = LastPlayedService();
  final FavoritesService _favoritesService = FavoritesService();
  final Uac2PreferencesService _preferencesService = Uac2PreferencesService();
  final AppPreferencesService _appPreferencesService = AppPreferencesService();
  final SongRepository _songRepository = SongRepository();
  final PlaylistService _playlistService = PlaylistService();
  final RustAudioService _rustAudioService = RustAudioService();
  final Uac2Service _uac2Service = Uac2Service.instance;
  final CastingService _castingService = CastingService.instance;
  bool get isCasting => _castingService.isActive;
  final ColorExtractionService _colorExtractionService =
      ColorExtractionService();
  final AlbumColorModePreferenceService _albumColorModePreferenceService =
      AlbumColorModePreferenceService();
  bool _priorityAnchorActive = false;
  bool _priorityAnchorEnabled = true;
  bool _midStreamUsbFallbackActive = false;
  bool _deadRustEngineRecoveryActive = false;
  late final AudioSessionManager _sessionManager;
  late final AudioEngineManager _playbackManager;
  RustAudioEngine? _rustEngine;
  StreamSubscription<PlaybackState>? _playbackStateSubscription;
  PlaybackState? _lastPlaybackState;
  Timer? _playbackDiagnosticsDebounceTimer;
  static const Duration _playbackDiagnosticsDebounce = Duration(
    milliseconds: 300,
  );
  Timer? _queueDebounceTimer;
  static const Duration _queueDebounce = Duration(milliseconds: 150);
  final RecentlyPlayedRepository _recentlyPlayedRepository =
      RecentlyPlayedRepository();
  final ReplayPlayTracker _replayPlayTracker = ReplayPlayTracker();
  static const MethodChannel _storageChannel = MethodChannel(
    'com.mossapps.flick/storage',
  );
  final Map<String, String> _stagedPlaybackPathCache = {};
  final Map<String, String> _convertedPlaybackPathCache = {};
  final Set<String> _unsupportedWavConversionSources = <String>{};
  final ValueNotifier<bool> usingRustBackendNotifier = ValueNotifier(false);
  final ValueNotifier<AudioOutputDiagnostics?> audioOutputDiagnosticsNotifier =
      ValueNotifier(null);
  final ValueNotifier<bool> bitPerfectProcessingLockedNotifier = ValueNotifier(
    false,
  );
  final ValueNotifier<bool> gaplessPlaybackEnabledNotifier = ValueNotifier(
    true,
  );
  final ValueNotifier<bool> duckOnInterruptionNotifier = ValueNotifier(true);
  final ValueNotifier<MilestoneType?> pendingMilestoneNotifier = ValueNotifier(
    null,
  );
  // Carries the day streak recorded on launch, or null when no popup is
  // pending. MainShell listens and shows the StreakPopup. Cleared on show.
  final ValueNotifier<int?> streakPopupNotifier = ValueNotifier(null);
  final MilestoneService _milestoneService = MilestoneService();
  bool get _usingRustBackend => usingRustBackendNotifier.value;
  set _usingRustBackend(bool value) => usingRustBackendNotifier.value = value;
  bool _rustBackendAvailable = false;
  VoidCallback? _bitPerfectLockedListener;
  bool _rustListenersAttached = false;
  bool _audioSessionConfigured = false;
  bool _wasPlayingBeforeAudioInterruption = false;
  bool _isDucked = false;
  VoidCallback? _rustStateListener;
  VoidCallback? _rustPositionListener;
  VoidCallback? _rustDurationListener;
  StreamSubscription<AudioInterruptionEvent>? _audioFocusSubscription;
  StreamSubscription<Map<Object?, Object?>>? _bluetoothDeviceEventSubscription;
  StreamSubscription<void>? _usbDacDetachSubscription;
  StreamSubscription<void>? _usbDacAttachSubscription;
  DateTime? _bluetoothDisconnectedAt;
  static const Duration _bluetoothReconnectWindow = Duration(seconds: 30);
  bool _audioInitialized = false;
  Future<void>? _audioInitInFlight;
  Future<void>? _appLaunchPreparationInFlight;
  Future<void> _playRequestQueue = Future<void>.value();
  Future<bool>? _rustInitInFlight;
  Future<void>? _rustCapabilityRefreshInFlight;
  Future<void>? _rustEnginePreparationInFlight;
  bool _suppressSequenceStateUpdates = false;
  String? _autoSyncGuardSongId;
  String? _restoredSongId;
  Duration _restoredPosition = Duration.zero;
  double _currentVolume = 1.0;

  /// Default volume for bit-perfect mode (25 %, safety level).
  /// Mapped to ~0.01 linear gain by Rust's volume_to_gain curve.
  static const double _bitPerfectDefaultVolume = 0.25;

  double get currentVolume => _currentVolume;

  /// Extended-volume boost (up to 200 %) toggle. Only the software (Rust)
  /// and system (ExoPlayer + LoudnessEnhancer) tiers may exceed 1.0.
  bool _extendedVolumeEnabled = false;
  int _currentBoostMb = 0;

  /// Effective ReplayGain for the current track ('off' | 'track' | 'album').
  /// Pushed to the Rust engine per-source; folded into the just_audio volume
  /// on the system tier.
  ReplayGainAppliedState _replayGainState = ReplayGainAppliedState.neutral;

  final ValueNotifier<bool> extendedVolumeEnabledNotifier =
      ValueNotifier<bool>(false);

  /// Lie-detector: set when a DAC that claimed hardware volume rejects
  /// writes or fails the GET_CUR health check.
  bool _hwVolumeFailed = false;
  VolumeTier _activeTier = VolumeTier.system;

  // Timer to periodically save position
  Timer? _positionSaveTimer;

  // Periodic health-check for hardware volume verification
  Timer? _hwVolumeHealthTimer;

  // State Notifiers
  final ValueNotifier<Song?> currentSongNotifier = _MutableValueNotifier(null);
  final ValueNotifier<bool> isPlayingNotifier = ValueNotifier(false);
  final ValueNotifier<Duration> positionNotifier = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> durationNotifier = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> bufferedPositionNotifier = ValueNotifier(
    Duration.zero,
  );

  /// True while a network-sourced song is being resolved for playback (HTTP
  /// stream attach or cache download). UI surfaces a loading indicator so the
  /// user sees that their tap was registered during the network round-trip.
  final ValueNotifier<bool> isNetworkLoadingNotifier = ValueNotifier(false);
  // ponytail: monotonically increasing token; only the most-recent network
  // play request is allowed to clear the loading flag. Upgrade path: a per-
  // song Set<int> if multiple concurrent network loads ever need tracking.
  int _networkLoadingGen = 0;

  // ponytail: guards the engine's position write during interactive seek
  // (vinyl spin). Local drag writes to positionNotifier stick; engine ticks
  // get re-enabled on endInteractiveSeek(). Upgrade path: per-source locks if
  // multiple interactive sources ever contend.
  bool _suppressPositionUpdatesFromEngine = false;
  void beginInteractiveSeek() => _suppressPositionUpdatesFromEngine = true;
  void endInteractiveSeek() => _suppressPositionUpdatesFromEngine = false;

  // Playback Mode State
  final ValueNotifier<ShuffleMode> shuffleModeNotifier = ValueNotifier(
    ShuffleMode.off,
  );
  ValueNotifier<bool> get isShuffleNotifier => _isShuffleCompat;
  late final ValueNotifier<bool> _isShuffleCompat = _ShuffleBoolNotifier(
    shuffleModeNotifier,
  );
  final ValueNotifier<LoopMode> loopModeNotifier = ValueNotifier(LoopMode.all);

  // A-B Repeat
  final ValueNotifier<Duration?> abRepeatANotifier = ValueNotifier(null);
  final ValueNotifier<Duration?> abRepeatBNotifier = ValueNotifier(null);

  // Playback Context
  PlaybackContext _playbackContext = PlaybackContext.unknown;
  PlaybackContext get playbackContext => _playbackContext;
  final ValueNotifier<PlaybackContext> playbackContextNotifier = ValueNotifier(
    PlaybackContext.unknown,
  );

  // Advance List Order
  AdvanceListOrder _advanceListOrder = AdvanceListOrder.alphabetical;
  AdvanceListOrder get advanceListOrder => _advanceListOrder;

  // Wrap-around queue: tapping a song mid-list queues preceding songs at the end.
  final ValueNotifier<bool> wrapAroundQueueNotifier = ValueNotifier(true);
  bool get wrapAroundQueue => wrapAroundQueueNotifier.value;

  final ValueNotifier<bool> autoplayOnQueueEndNotifier = ValueNotifier(true);

  // Category shuffle tracking
  final Set<String> _playedCategoryIds = {};

  // Playback Speed
  final ValueNotifier<double> playbackSpeedNotifier = ValueNotifier(1.0);
  final ValueNotifier<double> pitchSemitonesNotifier = ValueNotifier(0.0);

  // Queue State
  final ValueNotifier<List<Song>> queueNotifier = ValueNotifier(const []);
  final ValueNotifier<List<Song>> upNextNotifier = ValueNotifier(const []);
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
  // ignore: deprecated_member_use
  just_audio.ConcatenatingAudioSource? _audioSourceSequence;

  // Track previous position to detect repeat wrap-around for notification progress
  Duration _lastPosition = Duration.zero;

  // Track last notification update time to throttle updates
  DateTime _lastNotificationUpdate = DateTime.now();

  // Cache album color for notifications to avoid re-extracting on every update
  String? _lastNotificationColorSongId;
  int? _lastNotificationColor;

  final ValueNotifier<int> favoriteNotificationToggleNotifier = ValueNotifier(
    0,
  );

  final ValueNotifier<bool> playbackDesyncedNotifier = ValueNotifier(false);
  Song? _engineCurrentTrack;
  Timer? _desyncDetectionTimer;
  static const Duration _desyncThreshold = Duration(seconds: 3);

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
    _uac2Service.dapBitPerfectEnabledNotifier.addListener(() {
      unawaited(_handleBitPerfectPreferenceChanged());
    });
    selectedPlaybackModeNotifier.addListener(_updateBitPerfectProcessingLocked);
    initializedPlaybackModeNotifier.addListener(
      _updateBitPerfectProcessingLocked,
    );
    _uac2Service.bitPerfectEnabledNotifier.addListener(
      _updateBitPerfectProcessingLocked,
    );
    _uac2Service.dapBitPerfectEnabledNotifier.addListener(
      _updateBitPerfectProcessingLocked,
    );
    Uac2PreferencesService.tuning432HzNotifier.addListener(
      _on432HzTuningChanged,
    );
    _bitPerfectLockedListener = () {
      unawaited(reapplyEqualizer());
    };
    bitPerfectProcessingLockedNotifier.addListener(_bitPerfectLockedListener!);
    _updateBitPerfectProcessingLocked();
    _uac2Service.addStatusListener(_mirrorUsbVolumeFromUac2Status);
    _notifyQueueChanged();
    unawaited(_loadGaplessPlaybackPreference());
    unawaited(_loadDuckOnInterruptionPreference());
    unawaited(_loadCrossfadePreferences());
    unawaited(_loadFloatingPlayerPreference());
    unawaited(_loadPriorityAnchorPreference());
    _initBluetoothReconnectHandling();
    _initUsbDacDisconnectHandling();
    _initUsbDacAttachHandling();
    unawaited(_applyBluetoothCodecPrefs());
  }

  void _initBluetoothReconnectHandling() {
    _bluetoothDeviceEventSubscription = BluetoothService.instance.deviceEvents
        .listen((event) {
          final type = event['event'] as String?;
          if (type == 'disconnected') {
            if (isPlayingNotifier.value) {
              _bluetoothDisconnectedAt = DateTime.now();
            }
          } else if (type == 'connected') {
            unawaited(_applyBluetoothCodecPrefs());
            unawaited(_maybePauseOnBluetoothConnect());
          }
        });
  }

  void _initUsbDacDisconnectHandling() {
    _usbDacDetachSubscription = _uac2Service.deviceDetachedEvents.listen((
      _,
    ) async {
      if (!isPlayingNotifier.value) return;
      final enabled = await _appPreferencesService.getPauseOnUsbDacDisconnect();
      if (enabled) pause();
    });
  }

  void _initUsbDacAttachHandling() {
    _usbDacAttachSubscription = _uac2Service.deviceAttachedEvents.listen((
      _,
    ) async {
      if (!isPlayingNotifier.value) return;
      final enabled = await _appPreferencesService.getPauseOnUsbDacConnect();
      if (enabled) pause();
    });
  }

  /// Push the user's codec preference to the active A2DP device when codec
  /// control is enabled. Best-effort: the hidden API no-ops on apps not
  /// signed with the platform key, so the post-set verify loop in
  /// [BluetoothService.setCodecConfig] logs the real outcome.
  Future<void> _applyBluetoothCodecPrefs() async {
    final enabled = await _appPreferencesService.getBtEnableCodecControl();
    if (!enabled) return;
    final codecType = await _appPreferencesService.getBtPreferredCodec();
    if (codecType < 0) return; // automatic; nothing to force
    final devices = await BluetoothService.instance.getConnectedDevices();
    final preferred = await _appPreferencesService
        .getPreferredBluetoothDevice();
    final target = devices.isEmpty
        ? null
        : (preferred.isNotEmpty
                  ? devices.where((d) => d.address == preferred).firstOrNull
                  : null) ??
              devices.where((d) => d.isA2dp).firstOrNull ??
              devices.first;
    if (target == null) return;
    final sampleRate = await _appPreferencesService.getBtSampleRate();
    final bits = codecType == BluetoothCodecType.ldac
        ? await _appPreferencesService.getBtLdacBitsPerSample()
        : 0;
    final ldacBitrate = codecType == BluetoothCodecType.ldac
        ? BtLdacBitrate.fromName(
            await _appPreferencesService.getBtLdacBitrate(),
          ).kbps
        : 0;
    _debugLog(
      '[Bluetooth] Applying codec ${BluetoothCodecType.label(codecType)} '
      '(sr=$sampleRate bits=$bits ldacKbps=$ldacBitrate) to ${target.name}',
    );
    await BluetoothService.instance.setCodecConfig(
      address: target.address,
      codecType: codecType,
      sampleRate: sampleRate,
      bitsPerSample: bits,
      ldacBitrate: ldacBitrate,
    );
  }

  Future<void> _maybeResumeOnBluetoothReconnect() async {
    final disconnectTime = _bluetoothDisconnectedAt;
    if (disconnectTime == null) return;
    _bluetoothDisconnectedAt = null;
    final resumeEnabled = await _appPreferencesService
        .getResumeOnBluetoothReconnect();
    if (!resumeEnabled) return;
    if (DateTime.now().difference(disconnectTime) > _bluetoothReconnectWindow) {
      return;
    }
    if (currentSongNotifier.value == null || isPlayingNotifier.value) return;
    _debugLog(
      '[Bluetooth] Reconnected within ${_bluetoothReconnectWindow.inSeconds}s; '
      'resuming playback',
    );
    unawaited(resume());
  }

  // On Bluetooth connect: pause if opted in (overrides resume-on-reconnect);
  // otherwise fall back to the resume-on-reconnect behaviour.
  Future<void> _maybePauseOnBluetoothConnect() async {
    final pauseOnConnect = await _appPreferencesService
        .getPauseOnBluetoothConnect();
    if (pauseOnConnect && isPlayingNotifier.value) {
      _bluetoothDisconnectedAt = null;
      _debugLog('[Bluetooth] Connected; pausing due to pause-on-connect pref');
      pause();
      return;
    }
    _maybeResumeOnBluetoothReconnect();
  }

  Future<void> _loadCrossfadePreferences() async {
    final enabled = await _appPreferencesService.getCrossfadeEnabled();
    final duration = await _appPreferencesService.getCrossfadeDurationSecs();
    _crossfadeCurveIndex = await _appPreferencesService
        .getCrossfadeCurveIndex();
    _rustAudioService.crossfadeEnabledNotifier.value = enabled;
    _rustAudioService.crossfadeDurationNotifier.value = duration;
  }

  /// When the DAC/route reports a new volume level, keep [_currentVolume]
  /// aligned and propagate to the Rust engine.
  ///
  /// - **Hardware mode** (bit-perfect + DAC knob): mirrors the DAC level so
  ///   reconciliation keeps the engine pinned at 1.0.
  /// - **Software mode** (no hardware volume on DAC): the UAC2 status volume
  ///   comes from Android's STREAM_MUSIC level, which is unrelated to the
  ///   isochronous USB path.  We must NOT overwrite [_currentVolume] from it.
  ///   Instead, we only re-push the existing [_currentVolume] to the engine
  ///   to keep it in sync after status refreshes.
  void _mirrorUsbVolumeFromUac2Status(Uac2DeviceStatus? status) {
    if (status == null) {
      _hwVolumeFailed = false;
      unawaited(_reconcileVolumeForTier(_determineCurrentTier()));
      return;
    }
    if (!Platform.isAndroid) return;
    if (currentEngineType != AudioEngineType.usbDacExperimental) return;
    if (!status.hasVolumeControl) return;

    if (status.volumeMode == Uac2VolumeMode.hardware) {
      if (!isBitPerfectModeEnabled) return;
      final v = status.volume;
      if (v == null) return;
      if ((v - _currentVolume).abs() <= 0.01) return;
      _currentVolume = v.clamp(0.0, 1.0);
      unawaited(_reconcileVolumeForTier(_determineCurrentTier()));
    } else if (status.volumeMode == Uac2VolumeMode.software) {
      if (_usingRustBackend && _rustAudioService.isInitialized) {
        unawaited(_rustAudioService.setVolume(_currentVolume));
      }
      unawaited(_reconcileVolumeForTier(_determineCurrentTier()));
    }
  }

  Future<void> _handleBitPerfectPreferenceChanged() async {
    // When USB DAC bit-perfect is turned off, also turn off DAP bit-perfect
    // so the DAC receives non-bit-perfect data.
    if (!_uac2Service.isBitPerfectEnabledSync &&
        _uac2Service.isDapBitPerfectEnabledSync) {
      await setDapBitPerfectEnabled(false);
      return; // setDapBitPerfectEnabled will re-trigger this listener
    }

    // When both bit-perfect options are off on a DAP, force the engine
    // to Rust via Oboe so volume and DSP work correctly on the shared path.
    if (Platform.isAndroid &&
        audioOutputDiagnosticsNotifier.value?.detectedDap == true &&
        !_uac2Service.isBitPerfectEnabledSync &&
        !_uac2Service.isDapBitPerfectEnabledSync) {
      final pref = await _preferencesService.getAudioEnginePreference();
      if (pref == AudioEnginePreference.exoPlayer) {
        await _preferencesService.setAudioEnginePreference(
          AudioEnginePreference.rustOboe,
        );
      }
    }

    if (_usingRustBackend && _rustAudioService.isInitialized) {
      await _applyRustPlaybackProcessingPolicy(currentEngineType);
    } else {
      final player = _justAudioPlayer;
      if (player != null) {
        await player.setVolume(_currentVolume);
        await player.setSpeed(playbackSpeedNotifier.value);
      }
    }

    await reapplyEqualizer();
    await _refreshAudioOutputDiagnostics(
      reason: 'bit-perfect preference changed',
    );
  }

  Future<void> _loadGaplessPlaybackPreference() async {
    final enabled = await _preferencesService.getGaplessPlaybackEnabled();
    gaplessPlaybackEnabledNotifier.value = enabled;
  }

  Future<void> _loadDuckOnInterruptionPreference() async {
    final enabled = await _preferencesService.getDuckOnInterruption();
    duckOnInterruptionNotifier.value = enabled;
  }

  Future<void> setGaplessPlaybackEnabled(bool enabled) async {
    gaplessPlaybackEnabledNotifier.value = enabled;
    await _preferencesService.setGaplessPlaybackEnabled(enabled);
  }

  Future<void> setDuckOnInterruption(bool enabled) async {
    duckOnInterruptionNotifier.value = enabled;
    await _preferencesService.setDuckOnInterruption(enabled);
    if (Platform.isAndroid && _audioSessionConfigured) {
      await _applyAndroidAudioSessionConfig();
    }
  }

  /// Push the current crossfade preferences to the Rust engine.
  ///
  /// Called by the settings UI after persisting the new values. The actual
  /// engine command is routed through [_applyRustPlaybackProcessingPolicy],
  /// which suppresses crossfade in bit-perfect mode and under 432 Hz tuning.
  Future<void> applyCrossfadeSettings({
    required bool enabled,
    required double durationSecs,
  }) async {
    final wasEnabled = _rustAudioService.crossfadeEnabledNotifier.value;
    _rustAudioService.crossfadeEnabledNotifier.value = enabled;
    _rustAudioService.crossfadeDurationNotifier.value = durationSecs;
    _crossfadeCurveIndex = await _appPreferencesService
        .getCrossfadeCurveIndex();

    if (_usingRustBackend) {
      await _applyRustPlaybackProcessingPolicy(currentEngineType);
      // Only (re)queue the next track when crossfade transitions to on.
      // Re-queueing on every duration-slider drag spawns redundant decoders
      // and can race the engine's source provider.
      if (!wasEnabled &&
          enabled &&
          _isCrossfadeActive &&
          currentSongNotifier.value != null &&
          isPlayingNotifier.value) {
        try {
          await _queueNextTrackForGapless();
        } catch (e) {
          _debugLog('[crossfade] re-queue on enable failed: $e');
        }
      }
      return;
    }

    // just_audio (standard) engine: crossfade runs in-engine, but a track loaded
    // while crossfade was off used a ConcatenatingAudioSource (hard cut). On the
    // on-transition, reload the current track as a single source at the same
    // position so the engine can intercept the tail and crossfade.
    if (currentEngineType == AudioEngineType.normalAndroid &&
        !wasEnabled &&
        enabled &&
        currentSongNotifier.value != null &&
        isPlayingNotifier.value) {
      final song = currentSongNotifier.value!;
      final position = positionNotifier.value;
      try {
        await _runWithSuppressedSequenceStateUpdates(() async {
          await _playbackManager.load(song);
          if (position > Duration.zero) {
            await _playbackManager.seek(position);
          }
          await _playbackManager.play();
        });
      } catch (e) {
        _debugLog('[crossfade] reload on enable failed: $e');
      }
    }
  }

  /// Push the current crossfeed preference to the Rust engine.
  ///
  /// BS2B crossfeed is purely a Rust-engine DSP effect — just_audio has no
  /// equivalent. The preference is persisted first by the settings UI; the
  /// engine command is routed through [_applyRustPlaybackProcessingPolicy],
  /// which suppresses it in bit-perfect mode and under 432 Hz tuning.
  Future<void> applyCrossfeedSettings() async {
    if (_usingRustBackend) {
      await _applyRustPlaybackProcessingPolicy(currentEngineType);
    }
  }

  Future<void> _loadFloatingPlayerPreference() async {
    final enabled = await _appPreferencesService.getFloatingPlayerEnabled();
    if (enabled) {
      await _activateFloatingPlayer();
    }
  }

  /// Activates the floating overlay. Returns `true` if the overlay could be
  /// shown (Android + overlay permission granted), `false` if permission is
  /// still required — in which case [requestFloatingPlayerPermission] should
  /// be called first.
  Future<bool> setFloatingPlayerEnabled(bool enabled) async {
    if (enabled) {
      return _activateFloatingPlayer();
    }
    await _deactivateFloatingPlayer();
    return true;
  }

  Future<bool> requestFloatingPlayerPermission() async {
    return _floatingPlayerService.requestPermission();
  }

  Future<bool> canShowFloatingPlayer() async {
    if (!Platform.isAndroid) return false;
    return _floatingPlayerService.canDrawOverlays();
  }

  Future<bool> _activateFloatingPlayer() async {
    if (!Platform.isAndroid) return false;
    final canDraw = await _floatingPlayerService.canDrawOverlays();
    if (!canDraw) return false;
    _floatingPlayerActive = true;
    await _showFloatingPlayerOverlay();
    return true;
  }

  Future<void> _deactivateFloatingPlayer() async {
    _floatingPlayerActive = false;
    await _floatingPlayerService.hide();
  }

  Future<void> _showFloatingPlayerOverlay() async {
    if (!Platform.isAndroid) return;
    if (!_floatingPlayerActive) return;
    if (_appInForeground) return;
    final song = currentSongNotifier.value;
    if (song == null) return;
    await _floatingPlayerService.show(
      song: song,
      isPlaying: isPlayingNotifier.value,
      duration: durationNotifier.value,
      position: positionNotifier.value,
    );
  }

  Future<void> onAppPaused() async {
    if (!Platform.isAndroid) return;
    _appInForeground = false;
    final enabled = await _appPreferencesService.getFloatingPlayerEnabled();
    if (!enabled) return;
    await _activateFloatingPlayer();
  }

  Future<void> onAppResumed() async {
    _appInForeground = true;
    if (_floatingPlayerActive) {
      await _deactivateFloatingPlayer();
    }
    unawaited(_restoreBitPerfectEngineAfterForeground());
  }

  /// One UI suspends userspace USB transfers while the app is backgrounded,
  /// which makes direct USB fake-fail ("USB DAC disconnected") and fall back
  /// to ExoPlayer. Re-attach the bit-perfect engine once we're back.
  Future<void> _restoreBitPerfectEngineAfterForeground() async {
    if (!Platform.isAndroid ||
        !isPlayingNotifier.value ||
        currentEngineType != AudioEngineType.normalAndroid) {
      return;
    }
    try {
      await _sessionManager.syncRouteSelection(reason: 'app resumed');
      if (_sessionManager.selectedMode != AudioEngineType.usbDacExperimental ||
          currentEngineType == AudioEngineType.usbDacExperimental) {
        return;
      }
      if (currentSongNotifier.value == null) return;
      _debugLog(
        '[Engine] Foreground: restoring ${AudioEngineType.usbDacExperimental.logLabel}',
      );
      await _enqueuePlaybackRequest(() async {
        try {
          await _resumeInternal();
        } catch (e) {
          final recovered = await _handleDirectUsbStartupRefusal(
            e,
            song: currentSongNotifier.value,
            initialPosition: positionNotifier.value,
          );
          if (!recovered) rethrow;
        }
      });
    } catch (e) {
      _debugLog('[Engine] Foreground bit-perfect restore failed: $e');
    }
  }

  bool get _isGaplessActive =>
      _usingRustBackend &&
      gaplessPlaybackEnabledNotifier.value &&
      !isBitPerfectModeEnabled &&
      loopModeNotifier.value != LoopMode.one;

  bool get _isCrossfadeActive =>
      _usingRustBackend &&
      _rustAudioService.crossfadeEnabledNotifier.value &&
      !isBitPerfectProcessingLocked &&
      loopModeNotifier.value != LoopMode.one;

  bool get _shouldQueueNextTrack =>
      _usingRustBackend &&
      !isBitPerfectModeEnabled &&
      (_isGaplessActive || _isCrossfadeActive);

  void _notifyQueueChanged() {
    queueNotifier.value = List.unmodifiable(
      _queuedEntries.map((entry) => entry.song),
    );
  }

  void _notifyUpNextChanged() {
    upNextNotifier.value = upNext;
  }

  void _debounceQueueChanged() {
    _queueDebounceTimer?.cancel();
    _queueDebounceTimer = Timer(_queueDebounce, () {
      _notifyQueueChanged();
      if (_playlist.isNotEmpty && !_usingRustBackend) {
        unawaited(_rebuildPlaylist());
      }
    });
  }

  void _setCurrentIndex(int newIndex) {
    if (_currentIndex == newIndex) return;
    _currentIndex = newIndex;
    currentIndexNotifier.value = newIndex;
    _prefetchedNextSongId = null;
    _notifyUpNextChanged();
  }

  void _replacePlaybackContext(List<Song> songs) {
    _audioSourceSequence = null;
    _playlist
      ..clear()
      ..addAll(songs);
    _originalPlaylist
      ..clear()
      ..addAll(songs);
    _playlistQueueEntryIds
      ..clear()
      ..addAll(List<int?>.filled(songs.length, null));
    _queuedEntries.clear();
    _notifyQueueChanged();
    _notifyUpNextChanged();
  }

  List<String> _playlistNonQueueIds() {
    final ids = <String>[];
    for (var i = 0; i < _playlist.length; i++) {
      if (_playlistQueueEntryIds[i] == null) {
        ids.add(_playlist[i].id);
      }
    }
    return ids;
  }

  void syncAlbumArtPaths({
    required Iterable<String> filePaths,
    required String? albumArtPath,
  }) {
    final targetPaths = filePaths.where((path) => path.isNotEmpty).toSet();
    if (targetPaths.isEmpty) {
      return;
    }

    Song syncSong(Song song) {
      final path = song.filePath;
      if (path == null || !targetPaths.contains(path)) {
        return song;
      }
      if (song.albumArt == albumArtPath) {
        return song;
      }
      return _copySongWithAlbumArt(song, albumArtPath);
    }

    var queueChanged = false;

    for (var i = 0; i < _playlist.length; i++) {
      final updated = syncSong(_playlist[i]);
      if (!identical(updated, _playlist[i])) {
        _playlist[i] = updated;
      }
    }

    for (var i = 0; i < _originalPlaylist.length; i++) {
      final updated = syncSong(_originalPlaylist[i]);
      if (!identical(updated, _originalPlaylist[i])) {
        _originalPlaylist[i] = updated;
      }
    }

    for (var i = 0; i < _queuedEntries.length; i++) {
      final entry = _queuedEntries[i];
      final updatedSong = syncSong(entry.song);
      if (!identical(updatedSong, entry.song)) {
        _queuedEntries[i] = _QueueEntry(id: entry.id, song: updatedSong);
        queueChanged = true;
      }
    }

    var currentSongUpdated = false;
    final currentSong = currentSongNotifier.value;
    if (currentSong != null) {
      final updatedCurrentSong = syncSong(currentSong);
      if (!identical(updatedCurrentSong, currentSong)) {
        currentSongNotifier.value = updatedCurrentSong;
        currentSongUpdated = true;
      }
    }

    if (queueChanged) {
      _notifyQueueChanged();
    }

    if (currentSongUpdated) {
      _updateNotificationState();
    }
  }

  Song _copySongWithAlbumArt(Song song, String? albumArtPath) {
    return Song(
      id: song.id,
      title: song.title,
      artist: song.artist,
      albumArt: albumArtPath,
      duration: song.duration,
      fileType: song.fileType,
      resolution: song.resolution,
      sampleRate: song.sampleRate,
      bitDepth: song.bitDepth,
      replaygainTrackGain: song.replaygainTrackGain,
      replaygainTrackPeak: song.replaygainTrackPeak,
      replaygainAlbumGain: song.replaygainAlbumGain,
      replaygainAlbumPeak: song.replaygainAlbumPeak,
      startOffsetMs: song.startOffsetMs,
      endOffsetMs: song.endOffsetMs,
      ripper: song.ripper,
      readMode: song.readMode,
      accurateRip: song.accurateRip,
      testCrc: song.testCrc,
      copyCrc: song.copyCrc,
      album: song.album,
      albumArtist: song.albumArtist,
      trackNumber: song.trackNumber,
      discNumber: song.discNumber,
      year: song.year,
      genre: song.genre,
      filePath: song.filePath,
      folderUri: song.folderUri,
      dateAdded: song.dateAdded,
      isExternal: song.isExternal,
      sourcePackage: song.sourcePackage,
      sourceType: song.sourceType,
      remoteId: song.remoteId,
      remoteServerId: song.remoteServerId,
    );
  }

  /// Immediately reflects edited metadata in the in-memory playback state so
  /// the UI (mini/full player, notification, queue) updates without waiting
  /// for a DB watch tick or a track change.
  ///
  /// Fields with `null` mean “unchanged” (mirrors `SongRepository.updateSongMetadata`
  /// and `MetadataEditorService` semantics). Only `filePath`-matched songs are patched.
  void syncSongMetadata({
    required String filePath,
    String? title,
    String? artist,
    String? album,
    String? albumArtist,
    String? genre,
    int? year,
    int? trackNumber,
    int? discNumber,
  }) {
    if (filePath.isEmpty) return;
    final hasChange =
        title != null ||
        artist != null ||
        album != null ||
        albumArtist != null ||
        genre != null ||
        year != null ||
        trackNumber != null ||
        discNumber != null;
    if (!hasChange) return;

    Song syncSong(Song song) {
      if (song.filePath != filePath) return song;
      // Detect if anything would actually change.
      final nextTitle = title ?? song.title;
      final nextArtist = artist ?? song.artist;
      final nextAlbum = album ?? song.album;
      final nextAlbumArtist = albumArtist ?? song.albumArtist;
      final nextGenre = genre ?? song.genre;
      final nextYear = year ?? song.year;
      final nextTrack = trackNumber ?? song.trackNumber;
      final nextDisc = discNumber ?? song.discNumber;
      if (nextTitle == song.title &&
          nextArtist == song.artist &&
          nextAlbum == song.album &&
          nextAlbumArtist == song.albumArtist &&
          nextGenre == song.genre &&
          nextYear == song.year &&
          nextTrack == song.trackNumber &&
          nextDisc == song.discNumber) {
        return song;
      }
      return Song(
        id: song.id,
        title: nextTitle,
        artist: nextArtist,
        albumArt: song.albumArt,
        duration: song.duration,
        fileType: song.fileType,
        resolution: song.resolution,
        sampleRate: song.sampleRate,
        bitDepth: song.bitDepth,
        replaygainTrackGain: song.replaygainTrackGain,
        replaygainTrackPeak: song.replaygainTrackPeak,
        replaygainAlbumGain: song.replaygainAlbumGain,
        replaygainAlbumPeak: song.replaygainAlbumPeak,
        startOffsetMs: song.startOffsetMs,
        endOffsetMs: song.endOffsetMs,
        ripper: song.ripper,
        readMode: song.readMode,
        accurateRip: song.accurateRip,
        testCrc: song.testCrc,
        copyCrc: song.copyCrc,
        album: nextAlbum,
        albumArtist: nextAlbumArtist,
        trackNumber: nextTrack,
        discNumber: nextDisc,
        year: nextYear,
        genre: nextGenre,
        filePath: song.filePath,
        folderUri: song.folderUri,
        dateAdded: song.dateAdded,
        isExternal: song.isExternal,
        sourcePackage: song.sourcePackage,
        sourceType: song.sourceType,
        remoteId: song.remoteId,
        remoteServerId: song.remoteServerId,
      );
    }

    var queueChanged = false;

    for (var i = 0; i < _playlist.length; i++) {
      final updated = syncSong(_playlist[i]);
      if (!identical(updated, _playlist[i])) {
        _playlist[i] = updated;
      }
    }

    for (var i = 0; i < _originalPlaylist.length; i++) {
      final updated = syncSong(_originalPlaylist[i]);
      if (!identical(updated, _originalPlaylist[i])) {
        _originalPlaylist[i] = updated;
      }
    }

    for (var i = 0; i < _queuedEntries.length; i++) {
      final entry = _queuedEntries[i];
      final updatedSong = syncSong(entry.song);
      if (!identical(updatedSong, entry.song)) {
        _queuedEntries[i] = _QueueEntry(id: entry.id, song: updatedSong);
        queueChanged = true;
      }
    }

    var currentSongUpdated = false;
    final currentSong = currentSongNotifier.value;
    if (currentSong != null) {
      final updatedCurrentSong = syncSong(currentSong);
      if (!identical(updatedCurrentSong, currentSong)) {
        currentSongNotifier.value = updatedCurrentSong;
        currentSongUpdated = true;
      }
    }

    if (queueChanged) {
      _notifyQueueChanged();
    }
    _notifyUpNextChanged();

    if (currentSongUpdated) {
      _updateNotificationState();
    }
  }

  void _insertQueuedEntriesAfterCurrent() {
    if (_queuedEntries.isEmpty || _playlist.isEmpty) return;
    final insertIndex = (_currentIndex + 1).clamp(0, _playlist.length);
    for (var i = 0; i < _queuedEntries.length; i++) {
      final entry = _queuedEntries[i];
      _playlist.insert(insertIndex + i, entry.song);
      _playlistQueueEntryIds.insert(insertIndex + i, entry.id);
    }
    _notifyUpNextChanged();
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
    _notifyUpNextChanged();
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
      _removeFromAudioSequence(playlistIndex);
    }
    _notifyQueueChanged();
    _notifyUpNextChanged();
    if (_usingRustBackend || _audioSourceSequence == null) {
      _debounceQueueChanged();
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
  bool get isBitPerfectModeEnabled =>
      (currentEngineType == AudioEngineType.usbDacExperimental &&
          _uac2Service.isBitPerfectEnabledSync) ||
      (currentEngineType == AudioEngineType.dapInternalHighRes &&
          _uac2Service.isDapBitPerfectEnabledSync);
  bool get isBitPerfectProcessingLocked =>
      bitPerfectProcessingLockedNotifier.value;
  bool get isCurrentTrackDoP =>
      (Uac2PreferencesService.dsdOutputModeSync == DsdOutputMode.forceDop ||
          Uac2PreferencesService.dsdOutputModeSync == DsdOutputMode.native ||
          Uac2PreferencesService.dsdOutputModeSync == DsdOutputMode.auto) &&
      currentSongNotifier.value?.isDsd == true;

  void _updateBitPerfectProcessingLocked() {
    final locked =
        switch (currentEngineType) {
          AudioEngineType.usbDacExperimental => true,
          AudioEngineType.dapInternalHighRes =>
            _uac2Service.isDapBitPerfectEnabledSync,
          _ => false,
        } ||
        Uac2PreferencesService.is432HzTuningEnabledSync;
    if (bitPerfectProcessingLockedNotifier.value != locked) {
      bitPerfectProcessingLockedNotifier.value = locked;
    }
  }

  /// Listener for 432 Hz tuning changes. Crossfade is suppressed under tuning
  /// (the mix bypasses speed resampling), so re-applying the processing policy
  /// pushes the new crossfade state to the Rust engine immediately.
  void _on432HzTuningChanged() {
    _updateBitPerfectProcessingLocked();
    if (_usingRustBackend) {
      unawaited(_applyRustPlaybackProcessingPolicy(currentEngineType));
    }
  }

  void _debugLog(String message) {
    devLog(message);
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
    if (Platform.isAndroid && !_sessionManager.selectedMode.usesRustBackend) {
      await _ensureAndroidPlayer();
    }
    await reapplyEqualizer();
  }

  Future<void> setHiFiModeEnabled(bool enabled) async {
    await initAudio();
    await _sessionManager.setHiFiModeEnabled(enabled);
  }

  Future<void> setDapBitPerfectEnabled(bool enabled) async {
    await _preferencesService.setDapBitPerfectEnabled(enabled);
    _uac2Service.dapBitPerfectEnabledNotifier.value = enabled;
    rust_audio.audioSetDapBitPerfectEnabled(enabled: enabled);
    await _sessionManager.syncRouteSelection(
      reason: enabled
          ? 'Bit-perfect (DAP Internal) enabled'
          : 'Bit-perfect (DAP Internal) disabled',
    );
  }

  Future<void> setAudioEnginePreference(
    AudioEnginePreference preference,
  ) async {
    await _preferencesService.setAudioEnginePreference(preference);
    await initAudio();
    await _sessionManager.syncRouteSelection(
      reason: 'audio engine preference changed',
    );
  }

  Future<bool> isHiFiModeEnabled() async {
    await initAudio();
    return _sessionManager.isHiFiModeEnabled();
  }

  Future<bool> isDapBitPerfectEnabled() async {
    return _preferencesService.getDapBitPerfectEnabled();
  }

  Future<void> _initializeAudio() async {
    _debugLog('[Engine] Initializing audio manager');

    try {
      await Future.wait<void>([
        _preferencesService.initializeDeveloperModeCache(),
        _preferencesService.initializeKillIsochronousUsbOnQuitCache(),
        _preferencesService.initialize432HzTuningCache(),
        _preferencesService.initializeBtFlagsCache(),
        _preferencesService.getDsdOutputMode(),
        _sessionManager.initialize(),
        _uac2Service.isBitPerfectEnabled(),
      ]);
      final dapBitPerfect = await _preferencesService.getDapBitPerfectEnabled();
      _uac2Service.dapBitPerfectEnabledNotifier.value = dapBitPerfect;
      rust_audio.audioSetDapBitPerfectEnabled(enabled: dapBitPerfect);
      rust_audio.audioSet432HzTuningEnabled(
        enabled: Uac2PreferencesService.is432HzTuningEnabledSync,
      );

      _extendedVolumeEnabled =
          await _appPreferencesService.getExtendedVolumeEnabled();
      extendedVolumeEnabledNotifier.value = _extendedVolumeEnabled;

      final engineType = _sessionManager.selectedMode;
      if (engineType == AudioEngineType.usbDacExperimental ||
          engineType == AudioEngineType.dapInternalHighRes) {
        final savedVolume = await _preferencesService.getUsbSoftwareVolume();
        final hasSavedVolume = await _preferencesService.hasUsbSoftwareVolume();
        final bitPerfectOn =
            _uac2Service.isBitPerfectEnabledSync ||
            _uac2Service.isDapBitPerfectEnabledSync;
        if (bitPerfectOn && !hasSavedVolume) {
          // Bit-perfect safety default: 25 % when the user has never set
          // a USB software volume, so the DAC doesn't receive a 100 % signal.
          _currentVolume = _bitPerfectDefaultVolume;
        } else if (savedVolume != 1.0) {
          _currentVolume = savedVolume;
        }
      }

      _playbackManager.publishIdleState(_sessionManager.selectedMode);
      _audioInitialized = true;
      await _refreshAudioOutputDiagnostics(reason: 'audio initialized');
    } finally {
      _audioInitInFlight = null;
    }
  }

  Future<void> _deactivateAndroidAudioSession() async {
    if (!Platform.isAndroid || !_audioSessionConfigured) {
      return;
    }

    // Any in-flight interruption state is irrelevant once we release focus.
    _wasPlayingBeforeAudioInterruption = false;
    _isDucked = false;

    try {
      final session = await AudioSession.instance;
      await session.setActive(false);
    } catch (e) {
      _debugLog('[AudioFocus] Failed to deactivate Android audio session: $e');
    }
  }

  Future<void> _activateAudioSessionForRustEngine() async {
    if (!Platform.isAndroid) return;
    await _configureAndroidAudioSession();
    try {
      final session = await AudioSession.instance;
      final granted = await session.setActive(true);
      _debugLog('[AudioFocus] Rust engine focus request granted=$granted');
    } catch (e) {
      _debugLog(
        '[AudioFocus] Failed to activate audio session for Rust engine: $e',
      );
    }
  }

  Future<void> _releaseAndroidManagedAudioResources({
    required String reason,
  }) async {
    if (!Platform.isAndroid) {
      return;
    }

    _debugLog('[Engine] Releasing Android-managed audio resources ($reason)');
    await _disposeAndroidEngine();
    await _deactivateAndroidAudioSession();
  }

  Future<void> _configureAndroidAudioSession() async {
    if (!Platform.isAndroid || _audioSessionConfigured) {
      return;
    }

    try {
      final session = await AudioSession.instance;
      await _applyAndroidAudioSessionConfig();
      _audioFocusSubscription ??= session.interruptionEventStream.listen((
        event,
      ) {
        _onAudioInterruptionEvent(event);
      });
      _audioSessionConfigured = true;
    } catch (e) {
      _debugLog('[AudioFocus] Failed to configure Android audio session: $e');
    }
  }

  Future<void> _applyAndroidAudioSessionConfig() async {
    final session = await AudioSession.instance;
    // When ducking is enabled we keep the stream alive at reduced gain for
    // transient losses (notifications) instead of pausing. Users who prefer
    // a hard pause get androidWillPauseWhenDucked: true.
    await session.configure(
      const AudioSessionConfiguration.music().copyWith(
        androidWillPauseWhenDucked: !duckOnInterruptionNotifier.value,
      ),
    );
  }

  void _onAudioInterruptionEvent(AudioInterruptionEvent event) {
    _debugLog(
      '[AudioFocus] Interruption event: begin=${event.begin}, '
      'type=${event.type}, wasPlaying=$_wasPlayingBeforeAudioInterruption, '
      'playing=${isPlayingNotifier.value}',
    );

    if (event.begin) {
      if (event.type == AudioInterruptionType.duck &&
          duckOnInterruptionNotifier.value) {
        // Transient loss (notification sound): dip volume, keep playing.
        if (isPlayingNotifier.value) {
          unawaited(_setDucked(true));
        }
        return;
      }
      if (isPlayingNotifier.value) {
        _wasPlayingBeforeAudioInterruption = true;
        unawaited(_pauseInternal());
      }
      return;
    }

    // Interruption ended. Only resume if we were actually playing when it
    // started; otherwise a manual pause during the interruption would cause
    // an unwanted auto-resume.
    if (event.type == AudioInterruptionType.duck && _isDucked) {
      unawaited(_setDucked(false));
      return;
    }
    if (!_wasPlayingBeforeAudioInterruption) {
      return;
    }
    _wasPlayingBeforeAudioInterruption = false;

    switch (event.type) {
      case AudioInterruptionType.pause:
      case AudioInterruptionType.duck:
        unawaited(_resumeAfterAudioInterruption());
      case AudioInterruptionType.unknown:
        // Permanent focus loss (e.g. another app started long-form playback).
        // Stay paused and let the user explicitly resume.
        break;
    }
  }

  /// Duck gain relative to the user's volume. 0.2 ≈ -14 dB, enough for
  /// notification sounds to sit on top without killing the music.
  static const double _duckVolumeScale = 0.2;

  Future<void> _setDucked(bool ducked) async {
    if (_isDucked == ducked) return;
    _isDucked = ducked;
    // DoP over direct USB: software gain corrupts DoP markers, and the
    // exclusive device is not mixed with system sounds anyway. Leave as-is.
    if (isCurrentTrackDoP && _isDirectUsbPath) return;
    final volume = ducked ? _currentVolume * _duckVolumeScale : _currentVolume;
    try {
      if (_usingRustBackend && _rustAudioService.isInitialized) {
        await _rustAudioService.setVolume(volume);
      } else {
        await _justAudioPlayer?.setVolume(volume);
      }
    } catch (e) {
      _debugLog('[AudioFocus] Failed to ${ducked ? 'apply' : 'lift'} duck: $e');
    }
  }

  Future<void> _resumeAfterAudioInterruption() async {
    // The audio session may have been deactivated while we were paused
    // (e.g. by a route change or by the system). Re-activate it before
    // attempting to resume the Rust engine.
    await _activateAudioSessionForRustEngine();
    try {
      await _resumeInternal();
    } catch (e, stackTrace) {
      final recovered = await _handleDirectUsbStartupRefusal(
        e,
        song: currentSongNotifier.value,
        initialPosition: positionNotifier.value,
      );
      if (recovered) {
        return;
      }
      _debugLog('[AudioFocus] Auto-resume after interruption failed: $e');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<just_audio.AudioPlayer> _ensureAndroidPlayer() async {
    final existing = _justAudioPlayer;
    if (existing != null) {
      return existing;
    }

    await _configureAndroidAudioSession();
    final player = just_audio.AudioPlayer();
    _justAudioPlayer = player;
    int? lastEqSessionId;
    player.androidAudioSessionIdStream.listen((sessionId) {
      if (sessionId == null || sessionId == lastEqSessionId) return;
      if (!identical(_justAudioPlayer, player)) return;
      lastEqSessionId = sessionId;
      unawaited(reapplyEqualizer());
    });
    await player.setVolume(_currentVolume);
    await player.setSpeed(playbackSpeedNotifier.value);
    await _updateLoopMode();
    return player;
  }

  Future<void> _configureAndroidPlayer(just_audio.AudioPlayer player) async {
    if (_justAudioPlayer != player) {
      _justAudioPlayer = player;
    }

    if (Platform.isAndroid && _audioSessionConfigured) {
      try {
        final session = await AudioSession.instance;
        await session.setActive(true);
      } catch (e) {
        _debugLog('[AudioFocus] Failed to activate Android audio session: $e');
      }
    }

    await player.setVolume(_currentVolume);
    await player.setSpeed(playbackSpeedNotifier.value);
    await _updateLoopMode();
  }

  AndroidAudioEngine _createAndroidEngine() {
    final engine = AndroidAudioEngine(
      playerProvider: _ensureAndroidPlayer,
      sourcesBuilder: _buildAudioSources,
      sourceBuilder: _buildAudioSourceForSong,
      playlistProvider: () => List<Song>.unmodifiable(_playlist),
      configurePlayer: _configureAndroidPlayer,
      disposeEngine: _disposeAndroidEngine,
      shouldSuppressTrackSync: () =>
          _suppressSequenceStateUpdates || _isRebuildingPlaylist,
      shouldIgnoreTrack: (track) => track.filePath == null,
      shouldFastStartCurrentTrackOnly: () =>
          loopModeNotifier.value != LoopMode.all,
      crossfadeConfigProvider: () {
        final curves = AndroidCrossfadeCurve.values;
        final curve = curves[_crossfadeCurveIndex.clamp(0, curves.length - 1)];
        return AndroidCrossfadeConfig(
          enabled:
              _rustAudioService.crossfadeEnabledNotifier.value &&
              !isBitPerfectProcessingLocked,
          durationSecs: _rustAudioService.crossfadeDurationNotifier.value,
          curve: curve,
        );
      },
      onNextSong: _resolveAndroidCrossfadeNext,
      onTrackAdvanced: _onAndroidTrackAdvanced,
    );
    engine.onTrackEnded = () {
      if (_usingRustBackend) return;
      unawaited(_onSongFinished());
    };
    return engine;
  }

  Future<bool> _ensureRustBackendAvailable() async {
    if (_rustBackendAvailable && _rustAudioService.isInitialized) {
      return true;
    }
    if (_rustBackendAvailable && !_rustAudioService.isInitialized) {
      _debugLog(
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
      _debugLog('Rust audio backend unavailable: $e');
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

    if (song.isDsd) {
      final dsdMode = Uac2PreferencesService.dsdOutputModeSync;
      if (dsdMode == DsdOutputMode.native || dsdMode == DsdOutputMode.auto) {
        final rawRate = song.sampleRate ?? 2822400;
        final byteRate = rawRate ~/ 8;
        return Uac2AudioFormat(
          sampleRate: byteRate,
          bitDepth: 8,
          channels: 2,
          isDop: false,
          isNativeDsd: true,
        );
      }
      if (dsdMode == DsdOutputMode.forceDop) {
        final dopRate = Song.dsdToDopRate(song.sampleRate) ?? 176400;
        final dopBitDepth = (song.sampleRate ?? 0) >= 22579200 ? 32 : 24;
        return Uac2AudioFormat(
          sampleRate: dopRate,
          bitDepth: dopBitDepth,
          channels: 2,
          isDop: true,
        );
      } else {
        final pcmRate = Song.dsdToPcmRate(song.sampleRate) ?? 88200;
        final bitDepth = (song.sampleRate ?? 0) >= 22579200 ? 32 : 24;
        return Uac2AudioFormat(
          sampleRate: pcmRate,
          bitDepth: bitDepth,
          channels: 2,
        );
      }
    }

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

  bool _sameUac2Format(Uac2AudioFormat? a, Uac2AudioFormat? b) {
    if (a == null || b == null) {
      return false;
    }

    return a.sampleRate == b.sampleRate &&
        a.bitDepth == b.bitDepth &&
        a.channels == b.channels &&
        a.isDop == b.isDop &&
        a.isNativeDsd == b.isNativeDsd;
  }

  bool get _isDirectUsbPath =>
      Platform.isAndroid &&
      currentEngineType == AudioEngineType.usbDacExperimental;

  // ponytail: any Rust/bit-perfect path can be system-invisible to OEM
  // battery AI (Xiaomi/Tecno/Infinix), not just direct USB. Reuses the
  // existing usesRustBackend helper which excludes normalAndroid.
  // Excluded on DAP_INTERNAL_HIGH_RES: the anchor's Java AudioTrack gets
  // HiBy-forced onto the sole DIRECT slot, killing our native stream.
  bool get _isAnchorEligiblePath =>
      Platform.isAndroid &&
      currentEngineType.usesRustBackend &&
      currentEngineType != AudioEngineType.dapInternalHighRes;

  void _updatePriorityAnchor() {
    final shouldAnchor =
        _isAnchorEligiblePath && _priorityAnchorEnabled && isPlayingNotifier.value;
    if (shouldAnchor && !_priorityAnchorActive) {
      _uac2Service.startPriorityAnchor();
      _priorityAnchorActive = true;
    } else if (!shouldAnchor && _priorityAnchorActive) {
      _uac2Service.stopPriorityAnchor();
      _priorityAnchorActive = false;
    }
  }

  Future<void> _loadPriorityAnchorPreference() async {
    _priorityAnchorEnabled = await _appPreferencesService.getPriorityAnchorEnabled();
    _updatePriorityAnchor();
  }

  Future<void> setPriorityAnchorEnabled(bool value) async {
    _priorityAnchorEnabled = value;
    _updatePriorityAnchor();
  }

  void _onHwVolumeResult(bool success) {
    _hwVolumeFailed = !success;
    unawaited(_reconcileVolumeForTier(_determineCurrentTier()));
  }

  /// True when the Rust pipeline runs its pure passthrough callback, which
  /// ignores engine volume entirely (bit-perfect guarantee). EQ/tuning,
  /// crossfade and pitch force the DSP path, where engine gain works.
  bool get _isPassthroughActive {
    final passthrough =
        audioOutputDiagnosticsNotifier.value?.passthroughAllowed ?? false;
    if (!passthrough) return false;
    if (Uac2PreferencesService.is432HzTuningEnabledSync) return false;
    if (gaplessPlaybackEnabledNotifier.value) return false;
    if ((playbackSpeedNotifier.value - 1.0).abs() > 0.001) return false;
    return true;
  }

  /// Bit-perfect volume path: direct USB DAC or DAP internal hi-res engine.
  bool get _isBitPerfectVolumePath =>
      isBitPerfectModeEnabled &&
      (currentEngineType == AudioEngineType.usbDacExperimental ||
          currentEngineType == AudioEngineType.dapInternalHighRes);

  /// Whether the user can change volume right now. False in bit-perfect
  /// passthrough when the DAC has no hardware (UAC2 Feature Unit) volume —
  /// engine gain would corrupt the stream, so the slider must disable.
  bool get isVolumeAvailable =>
      _determineCurrentTier() != VolumeTier.unavailable;

  /// True when the DAC hardware (Feature Unit) volume is the active volume
  /// authority; the UI should display the DAC level only then. Otherwise the
  /// bar shows [currentVolume], which is what [setVolume] actually writes.
  bool get isHardwareVolumeAuthority =>
      _determineCurrentTier() == VolumeTier.hardware;

  /// Maximum volume the user may select right now. Extended boost (2.0) is
  /// only available on the software and system tiers when the toggle is on;
  /// hardware, passthrough, DoP and casting paths stay clamped at 1.0.
  double get maxVolume {
    if (!_extendedVolumeEnabled || _castingService.isActive) return 1.0;
    final tier = _determineCurrentTier();
    return (tier == VolumeTier.software || tier == VolumeTier.system)
        ? 2.0
        : 1.0;
  }

  /// Toggle extended volume at runtime. Disabling clamps the current volume
  /// back to 1.0 and releases any active LoudnessEnhancer boost.
  Future<void> setExtendedVolumeEnabled(bool enabled) async {
    if (_extendedVolumeEnabled == enabled) return;
    _extendedVolumeEnabled = enabled;
    extendedVolumeEnabledNotifier.value = enabled;
    if (!enabled && _currentVolume > 1.0) {
      await setVolume(1.0);
    } else {
      await _reconcileSystemVolumeBoost(
        _determineCurrentTier() == VolumeTier.system
            ? math.min(_currentVolume, 1.0) * _replayGainState.linear
            : 0.0,
      );
    }
  }

  /// Apply or release the LoudnessEnhancer boost on the just_audio session.
  /// [effectiveVolume] is the volume to realise on the system tier (already
  /// folded with the ReplayGain factor); pass 0.0 to release (e.g. when on
  /// another tier or casting). Boost is used whenever the effective volume
  /// exceeds 1.0 — from the extended-volume toggle or from ReplayGain gain.
  Future<void> _reconcileSystemVolumeBoost(double effectiveVolume) async {
    if (!Platform.isAndroid) {
      if (_currentBoostMb != 0) _currentBoostMb = 0;
      return;
    }
    final desiredMb = effectiveVolume > 1.0
        ? AndroidJustAudioProcessingService.volumeToBoostMb(effectiveVolume)
        : 0;
    if (desiredMb == _currentBoostMb) return;
    _currentBoostMb = desiredMb;
    try {
      await androidJustAudioProcessingService.setVolumeBoost(
        gainMb: desiredMb,
        audioSessionId: androidAudioSessionId,
      );
    } catch (e) {
      _debugLog('[VolFlow] LoudnessEnhancer boost failed: $e');
    }
  }

  VolumeTier _determineCurrentTier() => determineVolumeTier(
    isBitPerfectVolumePath: _isBitPerfectVolumePath,
    volumeMode: _uac2Service.currentDeviceStatus?.volumeMode,
    hwVolumeFailed: _hwVolumeFailed,
    isDoP: isCurrentTrackDoP && _isDirectUsbPath,
    autoSwitchDsdForVolume: Uac2PreferencesService.autoSwitchDsdForVolumeSync,
    isPassthrough: _isPassthroughActive,
    usingRustBackend: _usingRustBackend,
  );

  Future<void> _reconcileVolumeForTier(VolumeTier tier) async {
    _activeTier = tier;
    if (tier == VolumeTier.hardware) {
      _startHwVolumeHealthTimer();
    } else {
      _stopHwVolumeHealthTimer();
    }
    if (!_rustAudioService.isInitialized) return;
    switch (tier) {
      case VolumeTier.hardware:
        // DAC Feature Unit is the only volume authority — engine at unity.
        await _rustAudioService.setVolume(1.0);
        break;
      case VolumeTier.software:
        await _rustAudioService.setVolume(_currentVolume);
        break;
      case VolumeTier.system:
        await _rustAudioService.setVolume(_currentVolume);
        break;
      case VolumeTier.unavailable:
        break;
    }
  }

  /// Prefer [primary], then the current-song notifier, then the last engine
  /// playback snapshot so USB focus stays latched when Rust is ahead of or
  /// behind the notifier during gapless / crossfade / buffering.
  Song? _songForUac2Sync(Song? primary) =>
      primary ??
      currentSongNotifier.value ??
      _playbackManager.latestState?.currentTrack;

  Future<void> _syncUac2PlaybackStatus(
    Song? song, {
    required bool isPlaying,
  }) async {
    final resolved = _songForUac2Sync(song);
    // Rust state can flicker (idle between gapless segments, short internal
    // restarts) while the UI session is still "playing". Releasing direct USB
    // audio focus in that window races libusb teardown and surfaces as EIO.
    final directUsb = currentEngineType == AudioEngineType.usbDacExperimental;
    final effectiveIsPlaying =
        isPlaying || (directUsb && isPlayingNotifier.value && resolved != null);
    await _uac2Service.syncPlaybackStatus(
      song: resolved,
      isPlaying: effectiveIsPlaying,
      formatOverride: _deriveUac2FormatFromSong(resolved),
      playbackMode: currentEngineType,
    );
    await _refreshAudioOutputDiagnostics(
      reason: 'UAC2 status sync',
      activeSong: resolved,
    );
  }

  Future<void> _refreshAudioOutputDiagnostics({
    required String reason,
    Song? activeSong,
  }) async {
    final mode = currentEngineType;
    final activeEngineType = _playbackManager.activeEngineType ?? mode;
    final usesRustDiagnostics = activeEngineType.usesRustBackend;
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
    final deviceProfile = _mapValue(rustAudioState?['device_profile']);
    final detectedDap = _isDetectedDapProfile(deviceProfile);
    final detectedDapBrand = _detectedDapBrand(deviceProfile);

    final outputSignature = _stringValue(
      engineState?['output_signature'] ?? engineState?['outputSignature'],
    );
    final engineConfiguredSampleRate = _intValue(
      engineState?['sample_rate'] ?? engineState?['sampleRate'],
    );
    final outputStrategy =
        _stringValue(
          engineState?['output_strategy'] ?? engineState?['outputStrategy'],
        ) ??
        (outputSignature?.startsWith('android-uac2:') == true
            ? 'usb_direct'
            : outputSignature?.startsWith('android-shared:usb-dsd-native:') ==
                  true
            ? 'usb_dsd_native'
            : 'resampled_fallback');
    final engineRequestedSampleRate = _intValue(
      engineState?['requested_sample_rate'] ??
          engineState?['requestedSampleRate'],
    );
    final engineActualSampleRate = _intValue(
      engineState?['actual_sample_rate'] ?? engineState?['actualSampleRate'],
    );
    final engineResamplerActive =
        engineState?['resampler_active'] == true ||
        engineState?['resamplerActive'] == true;
    final enginePassthroughAllowed =
        engineState?['passthrough_allowed'] == true ||
        engineState?['passthroughAllowed'] == true;
    final dsdEffectiveMode = _stringValue(
      engineState?['dsd_effective_mode'] ?? engineState?['dsdEffectiveMode'],
    );
    final dsdTransport = _stringValue(
      engineState?['dsd_transport'] ?? engineState?['dsdTransport'],
    );
    final engineVerificationReason = _stringValue(
      engineState?['verification_reason'] ?? engineState?['verificationReason'],
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
    final directUsbEngineStateReason = _stringValue(
      directUsbState?['engine_state_reason'] ??
          directUsbState?['engineStateReason'],
    );
    final directUsbRefusalReason = _stringValue(
      directUsbState?['direct_mode_refusal_reason'] ??
          directUsbState?['directModeRefusalReason'],
    );
    final directUsbLastError = _stringValue(
      directUsbState?['last_error'] ?? directUsbState?['lastError'],
    );
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

    final androidManagedUsbRoute =
        deviceInfo.hasUsbDac ||
        deviceInfo.hasAttachedUac2Device ||
        deviceInfo.looksLikeUsbAudioRoute;

    final pathManagement = !Platform.isAndroid
        ? AudioPathManagement.androidManagedShared
        : !usesRustDiagnostics
        ? AudioPathManagement.androidManagedShared
        : outputSignature?.startsWith('android-alsa:') == true
        ? AudioPathManagement.alsaDirectDap
        : outputSignature?.startsWith('android-direct:') == true
        ? AudioPathManagement.managedDirectExclusive
        : (outputStrategy == 'usb_direct' &&
                  outputSignature?.startsWith('android-uac2:') == true) ||
              outputStrategy == 'usb_dsd_native'
        ? AudioPathManagement.directUsbExperimental
        : AudioPathManagement.androidManagedLowLatency;

    final isMixerManaged =
        pathManagement != AudioPathManagement.directUsbExperimental &&
        pathManagement != AudioPathManagement.alsaDirectDap &&
        pathManagement != AudioPathManagement.managedDirectExclusive;
    final requestedOutputSampleRate =
        (!usesRustDiagnostics ? trackFormat?.sampleRate : null) ??
        engineRequestedSampleRate ??
        (pathManagement == AudioPathManagement.directUsbExperimental
            ? directUsbConfiguredSampleRate
            : engineConfiguredSampleRate ?? trackFormat?.sampleRate);
    final reportedOutputSampleRate =
        (!usesRustDiagnostics ? null : null) ??
        engineActualSampleRate ??
        (pathManagement == AudioPathManagement.directUsbExperimental
            ? directUsbClockReportedSampleRate
            : engineConfiguredSampleRate);
    final resamplerActive =
        (usesRustDiagnostics && engineResamplerActive) ||
        (requestedOutputSampleRate != null &&
            usesRustDiagnostics &&
            reportedOutputSampleRate != null &&
            requestedOutputSampleRate != reportedOutputSampleRate);
    final passthroughAllowed =
        usesRustDiagnostics &&
        (enginePassthroughAllowed || directUsbBitPerfectVerified);
    // bitPerfect on USB paths comes from direct USB verification; on internal
    // DAP paths it means passthrough (no DSP) with no resampling — the DSD
    // bitstream or PCM stream reaches the DAC intact.
    final effectiveBitPerfect =
        (outputStrategy == 'usb_direct' || outputStrategy == 'usb_dsd_native')
        ? directUsbBitPerfectVerified
        : (usesRustDiagnostics && passthroughAllowed && !resamplerActive);
    final verificationReason =
        (!usesRustDiagnostics ? null : engineVerificationReason) ??
        (pathManagement == AudioPathManagement.directUsbExperimental
            ? directUsbRefusalReason ??
                  directUsbLastError ??
                  directUsbEngineStateReason ??
                  (!directUsbClockVerificationPassed
                      ? 'Direct USB verification failed'
                      : null)
            : null);
    final outputStrategyLabel = !usesRustDiagnostics
        ? 'Android shared'
        : switch (outputStrategy) {
            'dap_native' => 'DAP native',
            'dsd_native' => 'DSD native',
            'dsd_dop' => 'DSD DoP',
            'mixer_bit_perfect' => 'Mixer bit-perfect',
            'mixer_matched' => 'Mixer matched',
            'usb_direct' => 'USB direct',
            'usb_dsd_native' => 'USB DSD native',
            'resampled_fallback' => 'Resampled fallback',
            _ => 'Adaptive',
          };
    final backendDescription = !usesRustDiagnostics
        ? 'just_audio / ExoPlayer'
        : switch (outputStrategy) {
            'usb_dsd_native' when passthroughAllowed =>
              'Rust engine via USB direct native DSD (verified)',
            'usb_dsd_native' => 'Rust engine via USB direct native DSD',
            'usb_direct' when passthroughAllowed =>
              'Rust engine via libusb direct USB (verified)',
            'usb_direct' => 'Rust engine via libusb direct USB',
            'dsd_native' when passthroughAllowed =>
              'Rust engine via ENCODING_DSD AudioTrack (native DSD)',
            'dsd_native' => 'Rust engine via ENCODING_DSD AudioTrack',
            'dsd_dop' when passthroughAllowed =>
              'Rust engine via DoP over PCM carrier (verified)',
            'dsd_dop' => 'Rust engine via DoP over PCM carrier',
            'dap_native' when passthroughAllowed =>
              outputSignature?.startsWith('android-direct:') == true
                  ? 'Rust engine via AudioTrack DIRECT PCM (mixer bypass, verified)'
                  : outputSignature?.startsWith('android-alsa:') == true
                  ? 'Rust engine via ALSA direct DAP path (verified)'
                  : 'Rust engine via native DAP HAL path (verified)',
            'dap_native' =>
              outputSignature?.startsWith('android-direct:') == true
                  ? 'Rust engine via AudioTrack DIRECT PCM (mixer bypass)'
                  : outputSignature?.startsWith('android-alsa:') == true
                  ? 'Rust engine via ALSA direct DAP path'
                  : 'Rust engine via native DAP HAL path',
            'mixer_bit_perfect' =>
              'Rust engine via Android mixer bit-perfect path',
            'mixer_matched' =>
              'Rust engine via Oboe/AAudio (matched-rate Android-managed)',
            'resampled_fallback' =>
              'Rust engine via Oboe/AAudio with adaptive resampler fallback',
            _ => 'Rust adaptive playback engine',
          };

    final capabilityStateLabel = !usesRustDiagnostics
        ? (androidManagedUsbRoute
              ? 'Android shared (USB route)'
              : 'Android shared')
        : switch (outputStrategy) {
            'usb_dsd_native' when passthroughAllowed =>
              'Verified USB DSD native',
            'usb_dsd_native' => 'USB DSD native',
            'usb_direct' when passthroughAllowed => 'Verified USB direct',
            'usb_direct' => 'USB direct',
            'dsd_native' when passthroughAllowed => 'Verified DSD native',
            'dsd_native' => 'DSD native',
            'dsd_dop' when passthroughAllowed => 'Verified DSD DoP',
            'dsd_dop' => 'DSD DoP',
            'dap_native' when passthroughAllowed => 'Verified DAP native',
            'dap_native' => 'DAP native',
            'mixer_bit_perfect' when passthroughAllowed => 'Mixer bit-perfect',
            'mixer_matched' => 'Android matched',
            'resampled_fallback' when androidManagedUsbRoute =>
              'Android (resampled)',
            'resampled_fallback' => 'Android adaptive',
            _ => 'Adaptive output',
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
          usesRustDiagnostics &&
          pathManagement == AudioPathManagement.directUsbExperimental &&
          directUsbRegistered &&
          usbInterfaceClaimed,
      supportsDirectSampleRateSwitching:
          usesRustDiagnostics &&
          pathManagement == AudioPathManagement.directUsbExperimental &&
          directUsbClockVerificationPassed,
      supportsVerifiedBitPerfect:
          usesRustDiagnostics &&
          passthroughAllowed &&
          (pathManagement == AudioPathManagement.directUsbExperimental ||
              outputStrategy == 'mixer_bit_perfect' ||
              outputStrategy == 'dap_native' ||
              outputStrategy == 'dsd_native' ||
              outputStrategy == 'dsd_dop' ||
              outputStrategy == 'usb_dsd_native'),
      supportsAndroidManagedHighResOnly:
          activeEngineType == AudioEngineType.dapInternalHighRes,
      supportsInternalDapPathOnly:
          activeEngineType == AudioEngineType.dapInternalHighRes &&
          !deviceInfo.hasUsbDac,
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
    final activeServiceIntervalUs = _intValue(
      directUsbState?['active_service_interval_us'] ??
          directUsbState?['activeServiceIntervalUs'],
    );
    final activeMaxPacketBytes = _intValue(
      directUsbState?['active_max_packet_bytes'] ??
          directUsbState?['activeMaxPacketBytes'],
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
    final urbTransport =
        usesRustDiagnostics &&
            pathManagement == AudioPathManagement.directUsbExperimental
        ? UrbTransportInfo(
            activeAltSetting: activeAltSetting,
            activeEndpointAddress: activeEndpointAddress,
            activeSyncType: activeSyncType,
            activeUsageType: activeUsageType,
            activeRefresh: activeRefresh,
            activeServiceIntervalUs: activeServiceIntervalUs,
            activeMaxPacketBytes: activeMaxPacketBytes,
            transportFormat: transportFormat,
            transportSubslot: transportSubslot,
            transportBitResolution: transportBitResolution,
            bufferFillMs: bufferFillMs,
            bufferCapacityMs: bufferCapacityMs,
            bufferTargetMs: bufferTargetMs,
            framesPerPacket: framesPerPacket,
            underrunCount: underrunCount,
            producerFrames: producerFrames,
            consumerFrames: consumerFrames,
            driftMsFromTarget: driftMsFromTarget,
          )
        : null;

    audioOutputDiagnosticsNotifier.value = AudioOutputDiagnostics(
      selectedMode: _sessionManager.selectedMode,
      initializedMode: _sessionManager.initializedMode,
      detectedDap: detectedDap,
      detectedDapBrand: detectedDapBrand,
      pathManagement: pathManagement,
      outputStrategyLabel: outputStrategyLabel,
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
      directUsbRegistered: usesRustDiagnostics && directUsbRegistered,
      usbInterfaceClaimed: usesRustDiagnostics && usbInterfaceClaimed,
      usbStreamStable: usesRustDiagnostics && usbStreamStable,
      trackSampleRate: trackFormat?.sampleRate,
      requestedOutputSampleRate: requestedOutputSampleRate,
      reportedOutputSampleRate: reportedOutputSampleRate,
      resamplerActive: resamplerActive,
      passthroughAllowed: passthroughAllowed,
      activeOutputSignature: usesRustDiagnostics ? outputSignature : null,
      verificationReason: verificationReason,
      fallbackReason: _sessionManager.fallbackReason,
      capabilityFlags: capabilityFlags,
      urbTransport: urbTransport,
    );

    _debugLog(
      '[Diagnostics] $reason: mode=${mode.logLabel}, '
      'selected=${_sessionManager.selectedMode.logLabel}, '
      'path=$pathManagement, strategy=$outputStrategyLabel, '
      'route=${deviceInfo.routeSummary}, '
      'backend="$backendDescription", requested=$requestedOutputSampleRate, '
      'reported=$reportedOutputSampleRate, focus=$audioFocusHeld, '
      'usbRegistered=$directUsbRegistered, usbClaimed=$usbInterfaceClaimed, '
      'usbStreamStable=$usbStreamStable, '
      'mixerManaged=$isMixerManaged, signature=${outputSignature ?? 'none'}, '
      'alt=${activeAltSetting ?? -1}, endpoint=${activeEndpointAddress ?? -1}, '
      'sync=${activeSyncType ?? 'none'}, usage=${activeUsageType ?? 'none'}, '
      'refresh=${activeRefresh ?? -1}, '
      'clockOk=$effectiveClockOk, rateVerified=$effectiveRateVerified, '
      'dacPolicy=${effectiveDirectUsbDacClockPolicy ?? 'none'}, '
      'bitPerfect=$effectiveBitPerfect, '
      'serviceUs=${activeServiceIntervalUs ?? -1}, maxPacket=${activeMaxPacketBytes ?? -1}, '
      'bufferMs=${bufferFillMs ?? -1}/${bufferTargetMs ?? -1}/${bufferCapacityMs ?? -1}, '
      'framesPerPacket=${framesPerPacket ?? -1}, underruns=${underrunCount ?? -1}, '
      'producerFrames=${producerFrames ?? -1}, consumerFrames=${consumerFrames ?? -1}, '
      'driftMs=${driftMsFromTarget ?? -999}, '
      'resampler=$resamplerActive, passthrough=$passthroughAllowed, '
      'transport=${transportFormat ?? 'none'}/${transportBitResolution ?? -1}/'
      '${transportSubslot ?? -1}, refusal=${directUsbRefusalReason ?? 'none'}, '
      'verifyReason=${verificationReason ?? 'none'}, '
      'lastError=${directUsbLastError ?? 'none'}, '
      'fallback=${_sessionManager.fallbackReason ?? 'none'}, '
      'dsdMode=${dsdEffectiveMode ?? 'none'}, '
      'dsdTransport=${dsdTransport ?? 'none'}',
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

  bool _isDetectedDapProfile(Map<String, dynamic>? profile) {
    final kind = _mapValue(profile?['kind']);
    return kind?['Dap'] is String;
  }

  String? _detectedDapBrand(Map<String, dynamic>? profile) {
    final kind = _mapValue(profile?['kind']);
    return _stringValue(kind?['Dap']);
  }

  void _startReplayTracking(
    Song song, {
    Duration initialPosition = Duration.zero,
  }) {
    _replayPlayTracker.startTrack(song.id, initialPosition: initialPosition);
  }

  bool _shouldPersistSong(Song? song) {
    return song != null && !song.isExternal;
  }

  bool _allowsFavoriteActions(Song? song) {
    return song != null && !song.isExternal;
  }

  void _clearReplayTracking() {
    _replayPlayTracker.clear();
  }

  Future<void> _trackMilestones(Song song) async {
    await _milestoneService.addListenSeconds(song.duration.inSeconds);
    final milestone = await _milestoneService.checkMilestones();
    if (milestone != null) {
      await _milestoneService.markMilestoneShown(milestone);
      pendingMilestoneNotifier.value = milestone;
    }
  }

  /// Records that the user was active today (advancing the day-streak) and
  /// checks for any milestone unlocked purely by opening the app — e.g. a
  /// streak tier. Called once at startup after the milestone notifier is
  /// wired so the celebration dialog can still fire.
  Future<void> recordActivityDayAndCheckMilestones() async {
    if (!await _appPreferencesService.getStreaksEnabled()) return;
    final streak = await _milestoneService.recordActivityDay();
    final milestone = await _milestoneService.checkMilestones();
    if (milestone != null) {
      await _milestoneService.markMilestoneShown(milestone);
      pendingMilestoneNotifier.value = milestone;
    }
    // Defer the streak popup when a milestone unlocks so the celebration
    // dialog owns the moment; it will fire on the next launch.
    final snoozed = await _milestoneService.isStreakPopupSnoozed();
    if (milestone == null &&
        !snoozed &&
        streak >= 1 &&
        streakPopupNotifier.value == null) {
      streakPopupNotifier.value = streak;
    }
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
    if (counted && _shouldPersistSong(song)) {
      unawaited(_recentlyPlayedRepository.recordPlay(song.id));
      unawaited(_trackMilestones(song));
    }
  }

  void _setupRustAudioListeners() {
    if (_rustListenersAttached) return;
    _rustListenersAttached = true;

    _rustStateListener = () {
      if (!_usingRustBackend) return;

      final rustState = _rustAudioService.stateNotifier.value;
      // Treat buffering like playback for Android direct USB: releasing audio
      // focus while the Rust isochronous pump is still starting starves the
      // stream and surfaces as libusb I/O errors.
      final pipelineActive =
          rustState == RustPlaybackState.playing ||
          rustState == RustPlaybackState.crossfading ||
          rustState == RustPlaybackState.buffering;

      unawaited(
        _syncUac2PlaybackStatus(
          currentSongNotifier.value,
          isPlaying: pipelineActive,
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

    _rustAudioService.onTrackEnded = (endedPath) {
      if (!_usingRustBackend) return;
      unawaited(_onSongFinished(endedPath: endedPath));
    };
    _rustAudioService.onCrossfadeStarted = (fromPath, toPath) {
      _debugLog('[crossfade] ENGINE TRIGGERED: $fromPath -> $toPath');
    };
    _rustAudioService.onError = (message) {
      _debugLog('[PlayerService] Rust backend error: $message');
      if (Platform.isAndroid &&
          !_midStreamUsbFallbackActive &&
          currentEngineType == AudioEngineType.usbDacExperimental &&
          _isDirectUsbStartupRefusal(message)) {
        _midStreamUsbFallbackActive = true;
        final song = currentSongNotifier.value;
        final position = _lastPlaybackState?.position ?? Duration.zero;
        unawaited(() async {
          try {
            // Mid-stream USB error = DAC lost while playing. Respect the
            // pause-on-disconnect pref instead of resuming on the fallback.
            final pauseOnDisconnect = await _appPreferencesService
                .getPauseOnUsbDacDisconnect();
            var autoResumeAfterFallback = !pauseOnDisconnect;
            if (pauseOnDisconnect) {
              // "USB DAC disconnected" is often a lie (e.g. Samsung One UI
              // suspends userspace USB transfers when the app is backgrounded
              // while the DAC stays attached). Release the frozen direct-USB
              // session first so listDevices() does a real UsbManager query,
              // then only honour pause-on-disconnect for a genuine unplug.
              await _uac2Service.releaseAndroidDirectUsbRuntime();
              final stillAttached =
                  (await _uac2Service.listDevices()).isNotEmpty;
              if (stillAttached) {
                _debugLog(
                  '[Engine] Direct USB failed but DAC still attached; '
                  'treating as transient USB suspension, auto-resuming on '
                  'fallback',
                );
                autoResumeAfterFallback = true;
              }
            }
            final fellBack = await _handleDirectUsbStartupRefusal(
              message,
              song: song,
              initialPosition: position,
              autoResumeAfterFallback: autoResumeAfterFallback,
            );
            if (!fellBack) {
              await _refreshAudioOutputDiagnostics(
                reason: 'Rust backend error',
              );
            }
          } finally {
            _midStreamUsbFallbackActive = false;
          }
        }());
        return;
      }
      if (message.toLowerCase().contains('audio engine thread crashed')) {
        final song = currentSongNotifier.value;
        final position = _lastPlaybackState?.position ?? Duration.zero;
        unawaited(() async {
          final revived = await _handleDeadRustEngineFailure(
            StateError(message),
            song: song,
            initialPosition: position,
          );
          if (!revived) {
            await _refreshAudioOutputDiagnostics(
              reason: 'Rust engine thread crash',
            );
          }
        }());
        return;
      }
      unawaited(_refreshAudioOutputDiagnostics(reason: 'Rust backend error'));
    };
  }

  void _bindPlaybackState() {
    _playbackDiagnosticsDebounceTimer?.cancel();
    _playbackDiagnosticsDebounceTimer = null;
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
      if (!_suppressPositionUpdatesFromEngine &&
          positionNotifier.value != state.position) {
        positionNotifier.value = state.position;
        if (isAbRepeatActive) {
          checkAbRepeatBoundary(state.position);
        }
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
      final shouldTrackReplayFromState = shouldTrackReplayFromPlaybackState(
        usingRustBackend: shouldUseRust,
        previousPosition: previous?.position,
        currentPosition: state.position,
      );

      final previousTrackId = previous?.currentTrack?.id;
      final currentTrackId = state.currentTrack?.id;
      final shouldSyncLoopedNotification =
          shouldSyncNotificationForRepeatOneLoop(
            loopMode: loopModeNotifier.value,
            sameTrack:
                previousTrackId != null && previousTrackId == currentTrackId,
            previousPosition: _lastPosition,
            currentPosition: state.position,
            trackDuration: state.duration,
          );
      if (previousTrackId != currentTrackId) {
        if (currentTrackId != null && currentTrackId == _restoredSongId) {
          _clearRestoredPlaybackContext(songId: currentTrackId);
        }
        if (_autoSyncGuardSongId != null &&
            _autoSyncGuardSongId == currentTrackId) {
          _clearAutoSyncGuard();
        }
        if (state.currentTrack != null) {
          _debugLog('[Playback] Track changed: ${state.currentTrack!.title}');
        } else {
          _debugLog('[Playback] Track cleared');
        }
        if (state.currentTrack != null) {
          _syncCurrentIndexToTrack(state.currentTrack!);
          _startReplayTracking(
            state.currentTrack!,
            initialPosition: state.position,
          );
          // just_audio keeps its own volume per player: fold the new track's
          // ReplayGain in whenever playback advances (auto-advance incl.).
          if (!_usingRustBackend) {
            unawaited(_applyReplayGainForSystemTier(state.currentTrack!));
          }
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

      if (shouldSyncLoopedNotification && state.currentTrack != null) {
        _lastNotificationUpdate = DateTime.now();
        unawaited(_updateNotificationState());
      }

      if (shouldTrackReplayFromState) {
        _trackReplayProgress(state.position);
      }

      _lastPosition = state.position;

      _checkPlaybackDesync(state);

      final criticalDiagnosticsChange =
          previous == null ||
          previous.engine != state.engine ||
          previous.currentTrack?.id != state.currentTrack?.id ||
          previous.isPlaying != state.isPlaying;
      if (criticalDiagnosticsChange) {
        _playbackDiagnosticsDebounceTimer?.cancel();
        _playbackDiagnosticsDebounceTimer = null;
        unawaited(
          _refreshAudioOutputDiagnostics(
            reason: 'playback state changed',
            activeSong: state.currentTrack,
          ),
        );
      } else {
        _playbackDiagnosticsDebounceTimer?.cancel();
        _playbackDiagnosticsDebounceTimer = Timer(
          _playbackDiagnosticsDebounce,
          () {
            _playbackDiagnosticsDebounceTimer = null;
            final snap = _lastPlaybackState;
            unawaited(
              _refreshAudioOutputDiagnostics(
                reason: 'playback state changed',
                activeSong: snap?.currentTrack,
              ),
            );
          },
        );
      }
    });
  }

  Future<void> refreshNotificationState() {
    return _updateNotificationState();
  }

  Future<void> _toggleFavoriteFromNotification() async {
    final song = currentSongNotifier.value;
    if (_allowsFavoriteActions(song)) {
      await _favoritesService.toggleFavorite(song!.id);
      _updateNotificationState();
      favoriteNotificationToggleNotifier.value++;
    }
  }

  Future<void> _updateNotificationState() async {
    final song = currentSongNotifier.value;
    if (song == null) return;

    var isFav = false;
    if (_allowsFavoriteActions(song)) {
      try {
        isFav = await _favoritesService.isFavorite(song.id);
      } catch (e) {
        _debugLog('Failed to load favorite state: $e');
      }
    }

    int? notificationColor;
    try {
      final colorMode = await _albumColorModePreferenceService.getMode();
      if (colorMode != AlbumColorMode.off &&
          song.albumArt != null &&
          song.albumArt!.isNotEmpty) {
        final songId = song.id;
        if (songId == _lastNotificationColorSongId &&
            _lastNotificationColor != null) {
          notificationColor = _lastNotificationColor;
        } else {
          final color = await _colorExtractionService.extractDominantColor(
            song.albumArt,
          );
          if (color != null) {
            notificationColor = color.toARGB32();
            _lastNotificationColor = notificationColor;
            _lastNotificationColorSongId = songId;
          }
        }
      }
    } catch (e) {
      _debugLog('Failed to extract notification color: $e');
    }

    await _notificationService.updateNotification(
      song: song,
      isPlaying: isPlayingNotifier.value,
      duration: durationNotifier.value,
      position: positionNotifier.value,
      isShuffle: isShuffleNotifier.value,
      isFavorite: isFav,
      color: notificationColor,
    );

    await _showFloatingPlayerOverlay();
  }

  Future<void> _onSongFinished({String? endedPath}) {
    return _enqueuePlaybackRequest(
      () => _onSongFinishedInternal(endedPath: endedPath),
    );
  }

  Future<void> _onSongFinishedInternal({String? endedPath}) async {
    _debugLog(
      '_onSongFinished: loopMode=${loopModeNotifier.value}, currentIndex=$_currentIndex, playlistLength=${_playlist.length}, usingRustBackend=$_usingRustBackend, endedPath=$endedPath',
    );

    if (_isGaplessActive || _isCrossfadeActive) {
      await _handleGaplessTrackEnded();
      return;
    }

    if (!shouldHandleManualCompletion(
      usingRustBackend: _usingRustBackend,
      loopMode: loopModeNotifier.value,
    )) {
      _debugLog('_onSongFinished: skipping manual completion handling');
      return;
    }

    if (loopModeNotifier.value == LoopMode.stopAfterCurrent) {
      _debugLog('_onSongFinished: stopAfterCurrent, pausing');
      await _pauseInternal();
      await seek(Duration.zero);
      return;
    }

    if (loopModeNotifier.value == LoopMode.one) {
      final songToReplay = currentSongNotifier.value ?? _songAtCurrentIndex();
      if (songToReplay != null) {
        _debugLog('_onSongFinished: LoopMode.one, replaying current song');
        await _playInternal(songToReplay);
      }
    } else {
      _debugLog('_onSongFinished: Calling next()');
      await _nextInternal();
    }
  }

  Future<void> _handleGaplessTrackEnded() async {
    if (_playlist.isEmpty) return;

    if (loopModeNotifier.value == LoopMode.stopAfterCurrent) {
      await _pauseInternal();
      await seek(Duration.zero);
      return;
    }

    if (_currentIndex < _playlist.length - 1) {
      _setCurrentIndex(_currentIndex + 1);
    } else if (shuffleModeNotifier.value == ShuffleMode.songsAndCategories ||
        shuffleModeNotifier.value == ShuffleMode.categories) {
      await _advanceToRandomCategory();
      return;
    } else if (loopModeNotifier.value == LoopMode.all) {
      _setCurrentIndex(0);
    } else if (loopModeNotifier.value.isAdvanceMode) {
      await _advanceForMode(loopModeNotifier.value);
      return;
    } else {
      await _handleQueueEnd();
      return;
    }

    final currentSong = _songAtCurrentIndex();
    if (currentSong != null) {
      currentSongNotifier.value = currentSong;
      _playbackManager.updateTrack(currentSong);
    }
    _consumeQueueEntryAt(_currentIndex);
    _updatePriorityAnchor();

    if (_usingRustBackend && currentSong != null) {
      final expectedPath = await _resolveRustPath(currentSong);
      final enginePath = _rustAudioService.currentPath;
      if (expectedPath != null && enginePath != expectedPath) {
        await _playSongAtCurrentIndex();
        return;
      }
    }

    unawaited(_queueNextTrackForGapless());

    if (isPlayingNotifier.value && currentSong != null) {
      _updateNotificationState();
    }
  }

  void _stopPlayback() async {
    _wasPlayingBeforeAudioInterruption = false;
    await _savePosition();
    _positionSaveTimer?.cancel();
    _clearReplayTracking();
    _updatePriorityAnchor();
    try {
      await _playbackManager.stop();
    } catch (e) {
      _debugLog('Stop failed: $e');
    }
    await _refreshAudioOutputDiagnostics(reason: 'playback stopped');
    cancelSleepTimer();
  }

  /// Build audio sources for the playlist (gapless playback).
  // ignore: deprecated_member_use
  Future<just_audio.ConcatenatingAudioSource> _buildAudioSources() async {
    if (_playlist.isEmpty) {
      // ignore: deprecated_member_use
      return just_audio.ConcatenatingAudioSource(children: const []);
    }

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

    // ignore: deprecated_member_use
    _audioSourceSequence = just_audio.ConcatenatingAudioSource(
      children: sources,
    );
    return _audioSourceSequence!;
  }

  Future<just_audio.AudioSource> _buildAudioSourceForSong(Song song) async {
    if (song.filePath == null) {
      return just_audio.AudioSource.uri(Uri.parse(''));
    }

    final uri = await _resolvePlaybackUri(song);

    if (song.startOffsetMs != null && song.startOffsetMs! > 0) {
      final start = Duration(milliseconds: song.startOffsetMs!);
      final end = song.endOffsetMs != null && song.endOffsetMs! > 0
          ? Duration(milliseconds: song.endOffsetMs!)
          : null;
      return just_audio.ClippingAudioSource(
        child: just_audio.AudioSource.uri(uri),
        start: start,
        end: end,
      );
    }

    return just_audio.AudioSource.uri(uri);
  }

  Future<void> _insertIntoAudioSequence(int playlistIndex, Song song) async {
    if (_usingRustBackend || _audioSourceSequence == null) return;
    final source = await _buildAudioSourceForSong(song);
    _audioSourceSequence!.insert(playlistIndex, source);
  }

  void _removeFromAudioSequence(int playlistIndex) {
    if (_usingRustBackend || _audioSourceSequence == null) return;
    if (playlistIndex < _audioSourceSequence!.children.length) {
      _audioSourceSequence!.removeAt(playlistIndex);
    }
  }

  Future<Uri> _resolvePlaybackUri(Song song) async {
    // ponytail: HTTP-first for network sources. Hand ExoPlayer the ranged URL
    // so playback starts while bytes stream in, instead of blocking on a full
    // cache download before the first frame. Falls back to cache-then-play
    // (ensureLocal) for protocols without byte-range support (SMB/UPnP) or on
    // resolve failure. Matches the Rust backend's existing strategy.
    if (song.isNetworkSource) {
      try {
        final http = await RemoteSourceService.instance.resolveHttpPlayback(
          song,
        );
        if (http != null) return Uri.parse(http.url);
      } catch (e) {
        _debugLog(
          '[Playback] HTTP-first resolve failed for "${song.title}": $e',
        );
      }
    }
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

    if (song.isNetworkSource) {
      // Network songs always play from the local network cache: a cache hit
      // is instant (gapless/crossfade handoff), a miss downloads first.
      return RemoteSourceService.instance.ensureLocal(song);
    }

    final sourceKey = filePath;
    var resolvedPath = filePath;
    final parsed = Uri.tryParse(filePath);
    final isAndroidContentUri =
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        parsed?.scheme == 'content';

    final needsWavWork = isAndroidContentUri ||
        _shouldConvertToWav(song);
    if (needsWavWork) {
      final normalizedType = _playbackFileType(song);
      _debugLog(
        '[WAV-conv] resolve path: file=${song.title} '
        'normType=$normalizedType engine=$currentEngineType '
        'isContentUri=$isAndroidContentUri shouldConvert=${_shouldConvertToWav(song)}',
      );
    }

    if (isAndroidContentUri && _shouldStageContentUriForPlayback(song)) {
      final stagedPath = await _stageContentUriForPlayback(
        filePath,
        extensionHint: _preferredExtension(song),
      );
      _debugLog('[WAV-conv] staged: ${stagedPath ?? "null"}');
      if (stagedPath != null) {
        resolvedPath = stagedPath;
      }
    }

    if (_shouldConvertToWav(song)) {
      final convertedPath = await _convertPlaybackPathToWav(
        sourceKey: sourceKey,
        sourcePath: resolvedPath,
      );
      _debugLog(
        '[WAV-conv] converted: ${convertedPath ?? "null (fallback to native)"}',
      );
      if (convertedPath != null) {
        resolvedPath = convertedPath;
      }
    }

    if (needsWavWork) {
      _debugLog('[WAV-conv] final resolved path: $resolvedPath');
    }
    return resolvedPath;
  }

  bool _shouldStageForPlayback(Song song) {
    final normalized = _playbackFileType(song);
    return normalized == 'm4a' || normalized == 'aiff';
  }

  bool _shouldStageContentUriForPlayback(Song song) {
    return song.isExternal || _shouldStageForPlayback(song);
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
      _debugLog('Failed to stage content URI for playback: $e');
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
    // ponytail: standard engine also routes ALAC/AIFF via the Rust converter.
    // AAC-in-M4A fails the Symphonia probe (no default AAC), lands in
    // _unsupportedWavConversionSources, and falls back to the staged M4A
    // path so ExoPlayer plays it natively. Probe, not extension, decides A/B.
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
      _debugLog('[WAV-conv] skipping: not a file: scheme');
      return null;
    }

    final localPath = playbackUri.toFilePath();

    // Persistent cache: reuse a previously converted WAV, skipping probe +
    // conversion. Avoids re-reading/re-converting every launch.
    final persisted = await AlacConverterService.tryGetCachedWav(localPath);
    if (persisted != null) {
      _convertedPlaybackPathCache[sourceKey] = persisted;
      _debugLog('[WAV-conv] using persisted cache: $persisted');
      return persisted;
    }

    _debugLog(
      '[WAV-conv] convert check: sourceScheme=${playbackUri.scheme} '
      'sourcePath=$sourcePath',
    );
    final canConvert = await AlacConverterService.canConvertToWavFile(
      localPath,
    );
    _debugLog('[WAV-conv] canConvert=$canConvert localPath=$localPath');
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
      _debugLog('[WAV-conv] success: $convertedPath');
      return convertedPath;
    } catch (e) {
      _unsupportedWavConversionSources.add(sourceKey);
      _debugLog('Failed to convert playback path to WAV: $e');
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

    if (uri.scheme == 'content') {
      final stagedPath = await _stageContentUriForPlayback(
        resolvedPath,
        extensionHint: _preferredExtension(song),
      );
      if (stagedPath != null && stagedPath.isNotEmpty) {
        return stagedPath;
      }
      return null;
    }

    if (uri.scheme.isEmpty) {
      return resolvedPath;
    }

    return null;
  }

  Future<void> _prepareImmediatePlaybackAsset(Song song) async {
    if (!_shouldStageContentUriForPlayback(song) &&
        !_shouldConvertToWav(song)) {
      return;
    }

    await _resolvePreparedPlaybackPath(song);
  }

  RustAudioEngine _createRustEngine(AudioEngineType playbackMode) {
    return RustAudioEngine(
      playbackMode: playbackMode,
      rustAudioService: _rustAudioService,
      ensureInitialized: () => _ensureRustEngineInitialized(playbackMode),
      resolvePlaybackPath: _resolveRustPath,
      resolveHttpSource: _resolveRustHttpSource,
      disposeEngine: _disposeUsbEngine,
    );
  }

  /// HTTP-first source resolver for network songs. Returns null for local
  /// songs or protocols without byte-range support (then the engine falls back
  /// to cache-then-play via [_resolveRustPath]).
  Future<({String url, Map<String, String> headers})?> _resolveRustHttpSource(
    Song song,
  ) async {
    if (!song.isNetworkSource) return null;
    try {
      return await RemoteSourceService.instance.resolveHttpPlayback(song);
    } catch (e) {
      _debugLog('HTTP source resolve failed: $e');
      return null;
    }
  }

  Future<void> _ensureRustEngineInitialized(
    AudioEngineType playbackMode,
  ) async {
    final inFlight = _rustEnginePreparationInFlight;
    if (inFlight != null) {
      _debugLog(
        '[Engine] Waiting for in-flight Rust engine preparation to complete',
      );
      await inFlight;
      return;
    }

    final future = _doEnsureRustEngineInitialized(playbackMode);
    _rustEnginePreparationInFlight = future;
    try {
      await future;
    } finally {
      if (identical(_rustEnginePreparationInFlight, future)) {
        _rustEnginePreparationInFlight = null;
      }
    }
  }

  Future<void> _doEnsureRustEngineInitialized(
    AudioEngineType playbackMode,
  ) async {
    final requiresUsbDac =
        playbackMode == AudioEngineType.usbDacExperimental &&
        Platform.isAndroid;
    if (requiresUsbDac) {
      final deviceInfo = await AndroidAudioDeviceService.instance.refresh();
      if (!deviceInfo.hasUsbDac) {
        _debugLog('[Engine] USB init blocked: no USB DAC detected');
        throw StateError('Rust USB engine requires a USB DAC');
      }
    }

    if (!_rustAudioService.isInitialized) {
      _debugLog(
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
      var preferredSampleRate = await _resolvePreferredRustSampleRate(
        playbackMode,
      );
      if (playbackMode == AudioEngineType.usbDacExperimental) {
        _debugLog(
          '[Engine] Ensuring USB DAC is registered before engine preparation',
        );
        final dacRegistered = await _ensureUsbDacRegistered();
        if (!dacRegistered) {
          _debugLog(
            '[Engine] Failed to register USB DAC before engine preparation',
          );
          throw StateError('USB DAC registration failed');
        }

        directUsbFormat =
            _uac2Service.currentDeviceStatus?.currentFormat ??
            _uac2Service.lastKnownFormat;
        // Do NOT overwrite preferredSampleRate from the DAC's stored format.
        // The stored format may be stale (hardcoded 48000 from initial DAC
        // registration) or report 0 Hz (broken readback). The Rust engine
        // already has the track's actual sample rate via
        // requested_playback_format; passing null here lets it use that.
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

  Future<int?> _resolvePreferredRustSampleRate(
    AudioEngineType playbackMode,
  ) async {
    if (!Platform.isAndroid || playbackMode != AudioEngineType.rustOboe) {
      return null;
    }

    final debugState = await _uac2Service.getAndroidPlaybackDebugState();
    final rustAudioState = _mapValue(debugState?['rustAudioState']);
    final deviceProfile = _mapValue(rustAudioState?['device_profile']);
    if (!_isDetectedDapProfile(deviceProfile)) {
      return null;
    }

    final deviceInfo = await AndroidAudioDeviceService.instance.refresh();
    final internalRoute = switch (deviceInfo.routeType) {
      null || 'unknown' || 'internal' || 'wired' => true,
      _ => false,
    };
    if (!internalRoute || deviceInfo.hasUsbDac || deviceInfo.isBluetoothRoute) {
      return null;
    }

    final formatPreference = await _preferencesService.getFormatPreference();
    int? preferredSampleRate;
    if (formatPreference == Uac2FormatPreference.highestQuality) {
      // Bit-perfect DAP is OFF in rustOboe mode; Rust forces 48k via
      // dap_force_dsp. Pin the same rate here so the intent is explicit
      // and the Dart/Rust layers agree.
      preferredSampleRate = 48000;
    } else {
      preferredSampleRate = await _preferredSampleRateForFormatStrategy(
        formatPreference,
      );
    }
    if (preferredSampleRate == null || preferredSampleRate <= 0) {
      return null;
    }

    _debugLog(
      '[Engine] DAP managed playback pinned to $preferredSampleRate Hz '
      '(${formatPreference.name}) while Bit-perfect (DAP Internal) is disabled',
    );
    return preferredSampleRate;
  }

  Future<int?> _preferredSampleRateForFormatStrategy(
    Uac2FormatPreference formatPreference,
  ) async {
    switch (formatPreference) {
      case Uac2FormatPreference.highestQuality:
        final capabilityInfo = await _uac2Service
            .getAndroidAudioCapabilityInfo();
        final maxSampleRate = capabilityInfo.maxSampleRate;
        return maxSampleRate != null && maxSampleRate > 0
            ? maxSampleRate
            : 48000;
      case Uac2FormatPreference.compatibility:
        return 48000;
      case Uac2FormatPreference.custom:
        final customFormat = await _preferencesService.loadPreferredFormat();
        return customFormat?.sampleRate ?? 48000;
    }
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
      final hasPlaybackFormat =
          directUsbState?['playback_format_sample_rate'] != null;

      if (alreadyRegistered && hasPlaybackFormat) {
        _debugLog('[Engine] USB DAC already registered with playback format');
        return true;
      }

      _debugLog(
        '[Engine] Preparing USB DAC for playback (registered=$alreadyRegistered, hasFormat=$hasPlaybackFormat)',
      );

      // Use prepareAndroidExperimentalUsbPlayback which handles device selection,
      // registration, and format setting all in one
      // Try 48000 Hz first as it's more commonly supported than 44100 Hz
      final format =
          _uac2Service.currentDeviceStatus?.currentFormat ??
          Uac2AudioFormat(sampleRate: 48000, bitDepth: 16, channels: 2);

      final prepared = await _uac2Service.prepareAndroidExperimentalUsbPlayback(
        format: format,
      );

      if (!prepared) {
        _debugLog('[Engine] Failed to prepare USB DAC for playback');
        return false;
      }

      // Verify registration and format are set
      final verifyDiagnostics = await _uac2Service
          .getAndroidPlaybackDebugState();
      final verifyDirectUsbState = _mapValue(
        _mapValue(verifyDiagnostics?['rustAudioState'])?['direct_usb'],
      );
      final nowRegistered = verifyDirectUsbState?['registered'] == true;
      final nowHasFormat =
          verifyDirectUsbState?['playback_format_sample_rate'] != null;

      if (nowRegistered && nowHasFormat) {
        _debugLog(
          '[Engine] USB DAC successfully prepared: registered=$nowRegistered, hasFormat=$nowHasFormat, rate=${verifyDirectUsbState?['playback_format_sample_rate']}',
        );
      } else {
        _debugLog(
          '[Engine] USB DAC preparation incomplete: registered=$nowRegistered, hasFormat=$nowHasFormat',
        );
      }

      return nowRegistered && nowHasFormat;
    } catch (e) {
      _debugLog('[Engine] Error ensuring USB DAC registration: $e');
      return false;
    }
  }

  Future<void> _applyRustPlaybackProcessingPolicy(
    AudioEngineType playbackMode,
  ) async {
    if (!_rustAudioService.isInitialized) {
      return;
    }

    // The engine can remain in passthrough after bit-perfect is disabled.
    // Select DSP before sending software volume so the callback applies it.
    if (!isBitPerfectModeEnabled) {
      await _rustAudioService.setPipelineModePassthrough(false);
    }

    if (isBitPerfectModeEnabled) {
      if (playbackMode == AudioEngineType.usbDacExperimental ||
          playbackMode == AudioEngineType.dapInternalHighRes) {
        await _rustAudioService.setPipelineModePassthrough(true);
      }
      await _reconcileVolumeForTier(_determineCurrentTier());
      await _rustAudioService.setPlaybackSpeed(1.0);
      await _rustAudioService.setPitchShiftSemitones(0.0);
    } else if (playbackMode == AudioEngineType.usbDacExperimental) {
      await _rustAudioService.setVolume(_currentVolume);
      await _rustAudioService.setPlaybackSpeed(1.0);
      await _rustAudioService.setPitchShiftSemitones(0.0);
      await _rustAudioService.setCrossfade(
        enabled: false,
        durationSecs: _rustAudioService.crossfadeDurationNotifier.value,
      );
    } else {
      await _rustAudioService.setVolume(_currentVolume);
      await _rustAudioService.setPlaybackSpeed(playbackSpeedNotifier.value);
      // Crossfade is suppressed whenever DSP processing is locked out — this
      // includes 432 Hz tuning, where the crossfade mix bypasses speed
      // resampling and would emit audio at the wrong pitch.
      final crossfadeOn =
          !isBitPerfectProcessingLocked &&
          _rustAudioService.crossfadeEnabledNotifier.value;
      await _rustAudioService.setCrossfade(
        enabled: crossfadeOn,
        durationSecs: _rustAudioService.crossfadeDurationNotifier.value,
      );
    }

    if (!isBitPerfectProcessingLocked) {
      final curveIndex = await _appPreferencesService.getCrossfadeCurveIndex();
      final curves = <rust_audio.CrossfadeCurveType>[
        rust_audio.CrossfadeCurveType.equalPower,
        rust_audio.CrossfadeCurveType.linear,
        rust_audio.CrossfadeCurveType.squareRoot,
        rust_audio.CrossfadeCurveType.sCurve,
      ];
      final curve = curves[curveIndex.clamp(0, curves.length - 1)];
      await _rustAudioService.setCrossfadeCurve(curve);
    }

    await reapplyEqualizer();
    // Crossfeed is a headphone refinement for the Rust DSP path and has no
    // just_audio equivalent; it is suppressed whenever DSP is locked out
    // (bit-perfect passthrough, 432 Hz tuning).
    final crossfeedLevel = await _appPreferencesService.getCrossfeedLevel();
    await _rustAudioService.setCrossfeed(
      isBitPerfectProcessingLocked ? 0 : crossfeedLevel,
    );
    await _rustAudioService.setPitchShiftSemitones(
      pitchSemitonesNotifier.value,
    );
    _updatePriorityAnchor();
  }

  Future<bool> _retryAndroidDirectUsbPreparationWithFallbackRate({
    required Object initialError,
    required Uac2AudioFormat currentFormat,
  }) async {
    if (!_isDirectUsbClockSetupFailure(initialError.toString())) {
      return false;
    }
    if (await _uac2Service.isBitPerfectEnabled()) {
      _debugLog(
        '[Engine] Bit-perfect (USB DAC) requires an exact verified DAC rate; '
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

    _debugLog(
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

    _debugLog('[Engine] Disposing Android engine');

    try {
      await player.stop();
    } catch (_) {}

    await player.dispose();
    await _deactivateAndroidAudioSession();
    _justAudioPlayer = null;
    _audioSourceSequence = null;
  }

  Future<void> _disposeUsbEngine() async {
    if (!_rustAudioService.isInitialized) return;

    _debugLog('[Engine] Disposing Rust engine');
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

    // ALWAYS fully dispose the outgoing engine before initializing the new one.
    // This prevents USB "Resource busy" from overlapping sessions.
    if (from != to || from == null) {
      if (_rustEngine != null) {
        _debugLog('[Engine] Full dispose of Rust engine before ${to.logLabel}');
        await _disposeUsbEngine();
      }
      if (_justAudioPlayer != null) {
        _debugLog(
          '[Engine] Full dispose of Android engine before ${to.logLabel}',
        );
        await _disposeAndroidEngine();
      }
    }

    if (to == AudioEngineType.usbDacExperimental) {
      await _releaseAndroidManagedAudioResources(
        reason: 'switching to USB_DAC_EXPERIMENTAL',
      );
    }

    final hasDetachedAndroidPrewarm = _justAudioPlayer != null;
    if (hasDetachedAndroidPrewarm) {
      _debugLog(
        '[Engine] Disposing detached Android prewarm before ${to.logLabel}',
      );
      await _disposeAndroidEngine();
    }

    if (to.usesRustBackend) {
      await _playbackManager.ensureEngine(
        engineType: to,
        createEngine: () async {
          _rustEngine = _createRustEngine(to);
          return _rustEngine!;
        },
      );
      _usingRustBackend = true;
      if (to != AudioEngineType.usbDacExperimental) {
        await _activateAudioSessionForRustEngine();
      }
      await _reconcileVolumeForTier(_determineCurrentTier());
    } else {
      await _playbackManager.ensureEngine(
        engineType: to,
        createEngine: () async => _createAndroidEngine(),
      );
      _usingRustBackend = false;
    }

    _debugLog(
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

  void _syncCurrentIndexToTrack(Song song) {
    if (_playlist.isEmpty) {
      return;
    }

    final resolvedIndex = _playlist.indexWhere((entry) => entry.id == song.id);
    if (resolvedIndex == -1 || resolvedIndex == _currentIndex) {
      return;
    }

    _setCurrentIndex(resolvedIndex);
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

    _debugLog(
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
      case AudioEngineType.rustOboe:
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

        var trackFormat = _deriveUac2FormatFromSong(song);
        if (trackFormat == null) {
          final resolvedPath = await _resolveRustPath(song);
          if (resolvedPath != null && resolvedPath.isNotEmpty) {
            try {
              final probed = await rust_audio.audioProbeFormat(
                path: resolvedPath,
              );
              final probedBitDepth = probed.bitsPerSample ?? 16;
              _debugLog(
                '[Engine] Metadata missing — probed format: '
                '${probed.sampleRate}Hz/$probedBitDepth-bit/'
                '${probed.channels}ch',
              );
              trackFormat = Uac2AudioFormat(
                sampleRate: probed.sampleRate,
                bitDepth: probedBitDepth,
                channels: probed.channels,
              );
            } catch (e) {
              _debugLog('[Engine] Format probe failed: $e');
            }
          }
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
        }

        final alreadyInUsbMode =
            _sessionManager.initializedMode ==
                AudioEngineType.usbDacExperimental &&
            _rustEngine != null;
        final requestedUsbOutputFormat = alreadyInUsbMode
            ? await _uac2Service.suggestAndroidExperimentalUsbOutputFormat(
                requested: trackFormat,
              )
            : trackFormat;
        final currentUsbFormat =
            _uac2Service.lastKnownFormat ??
            _uac2Service.currentDeviceStatus?.currentFormat;
        final targetUsbOutputFormat = requestedUsbOutputFormat ?? trackFormat;
        final formatMatches =
            alreadyInUsbMode &&
            _sameUac2Format(currentUsbFormat, targetUsbOutputFormat);

        if (formatMatches) {
          _debugLog(
            '[Engine] USB engine already active with matching format '
            '(${targetUsbOutputFormat.sampleRate}Hz/'
            '${targetUsbOutputFormat.bitDepth}-bit/'
            '${targetUsbOutputFormat.channels}ch), skipping re-preparation',
          );
          _sessionManager.clearFallbackReason();
          return normalizedEngine;
        }

        final prepared = await _uac2Service
            .prepareAndroidExperimentalUsbPlayback(
              format: targetUsbOutputFormat,
            );
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

        final preparedUsbFormat =
            _uac2Service.currentDeviceStatus?.currentFormat ??
            _uac2Service.lastKnownFormat ??
            trackFormat;
        final needsDirectUsbPrewarm =
            alreadyInUsbMode &&
            !_sameUac2Format(currentUsbFormat, preparedUsbFormat);
        if (needsDirectUsbPrewarm && _rustAudioService.isInitialized) {
          _debugLog(
            '[Engine] Prewarming active USB engine for '
            '${preparedUsbFormat.sampleRate}Hz/${preparedUsbFormat.bitDepth}-bit/'
            '${preparedUsbFormat.channels}ch before playback',
          );
          _uac2Service.setPrewarming();
          await _rustAudioService.prepareEngine(
            preferredSampleRate: preparedUsbFormat.sampleRate,
          );
          await _applyRustPlaybackProcessingPolicy(normalizedEngine);
        }

        await _rustAudioService.setHighResMode(false);
        _sessionManager.clearFallbackReason();
        return normalizedEngine;
    }
  }

  /// Play a specific song.
  Future<void> play(
    Song song, {
    List<Song>? playlist,
    PlaybackContext? context,
  }) {
    _debugLog('[UI] tap(${song.id})');
    if (context != null) setPlaybackContext(context);
    // Immediate UI feedback: surface the loading state synchronously so the
    // mini-player shows a spinner before the (possibly queued) playback
    // request even starts running. Cleared by _playInternal's finally.
    if (song.isNetworkSource) isNetworkLoadingNotifier.value = true;
    return _enqueuePlaybackRequest(
      () => _playInternal(song, playlist: playlist),
    );
  }

  Future<void> _enqueuePlaybackRequest(Future<void> Function() action) {
    _debugLog('[PlayerService] _enqueuePlaybackRequest called');
    final operation = _playRequestQueue
        .then<void>((_) async {
          _debugLog(
            '[PlayerService] _enqueuePlaybackRequest: previous operation complete, executing action',
          );
          try {
            await action();
          } catch (e, stack) {
            _debugLog(
              '[PlayerService] _enqueuePlaybackRequest action error: $e\n$stack',
            );
            rethrow;
          }
        })
        .catchError((e) {
          _debugLog('[PlayerService] _enqueuePlaybackRequest queue error: $e');
        });
    _playRequestQueue = operation;
    return operation;
  }

  List<Song> _wrapAroundPlaylist(List<Song> songs, Song current) {
    final start = songs.indexWhere((s) => s.id == current.id);
    if (start <= 0) return songs;
    return [...songs.sublist(start), ...songs.sublist(0, start)];
  }

  Future<void> _playInternal(Song song, {List<Song>? playlist}) async {
    await initAudio();
    final loadingGen = ++_networkLoadingGen;
    try {
      _debugLog(
        '[Playback] play() called for ${song.title} '
        '(selected mode: ${_sessionManager.selectedMode.logLabel})',
      );

      _positionSaveTimer?.cancel();
      clearAbRepeat();

      if (playlist != null) {
        final sourcePlaylist = wrapAroundQueueNotifier.value
            ? _wrapAroundPlaylist(playlist, song)
            : playlist;
        _replacePlaybackContext(sourcePlaylist);
        _setCurrentIndex(_playlist.indexWhere((entry) => entry.id == song.id));
        if (isShuffleNotifier.value) {
          final shuffled = buildShufflePlaybackOrder(
            songs: _playlist,
            current: song,
          );
          _playlist
            ..clear()
            ..addAll(shuffled);
          _playlistQueueEntryIds
            ..clear()
            ..addAll(List<int?>.filled(shuffled.length, null));
          _setCurrentIndex(0);
        }
        _insertQueuedEntriesAfterCurrent();
      } else {
        final existingIndex = _playlist.indexWhere(
          (entry) => entry.id == song.id,
        );
        if (existingIndex == -1) {
          _replacePlaybackContext([song]);
          _setCurrentIndex(0);
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

      if (_castingService.isActive) {
        final handled = await _castingService.delegatePlay(song);
        if (handled) return;
      }

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
        _debugLog(
          '[Engine] Playback route resolved to ${activeEngine.logLabel}',
        );
        if (_usingRustBackend) {
          await _applyRustPlaybackProcessingPolicy(activeEngine);
          // ReplayGain must reach the engine before the play command so the
          // spawned source is stamped with this track's gain.
          await _refreshReplayGainForSong(song, pushSpawnDefault: true);
        }
        await _runWithSuppressedSequenceStateUpdates(() async {
          await _playbackManager.playTrack(song);
        });
        if (!_usingRustBackend) {
          unawaited(_applyReplayGainForSystemTier(song));
        }
        _ensurePositionSaveTimer();
        _updatePriorityAnchor();
        if (_shouldQueueNextTrack && _playlist.length > 1) {
          unawaited(_queueNextTrackForGapless());
        }
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
      final rustRecovered = await _handleDeadRustEngineFailure(
        e,
        song: song,
        initialPosition: Duration.zero,
      );
      if (rustRecovered) {
        return;
      }
      _debugLog(
        '[Playback] play() failed for ${song.title} '
        'on ${currentEngineType.logLabel}: $e',
      );
      debugPrintStack(stackTrace: stackTrace);
      rethrow;
    } finally {
      // Only the most-recent play request is allowed to clear the loading
      // flag. Superseded requests (user tapped another song while this one
      // was still queued/loading) leave it untouched so the spinner stays up
      // until the latest tap resolves.
      if (loadingGen == _networkLoadingGen) {
        isNetworkLoadingNotifier.value = false;
      }
    }
  }

  Future<void> _playSongAtCurrentIndex() async {
    final song = _songAtCurrentIndex();
    if (song == null) {
      return;
    }
    await _playInternal(song);
  }

  Future<void> _queueNextTrackForGapless() async {
    if (!_shouldQueueNextTrack || _playlist.isEmpty) return;

    final isLastTrack = _currentIndex >= _playlist.length - 1;
    if (isLastTrack && loopModeNotifier.value != LoopMode.all) return;

    final nextIndex = isLastTrack ? 0 : _currentIndex + 1;
    final nextSong = _playlist[nextIndex];

    // HTTP-first: try a direct ranged stream, fall back to cache-then-play.
    if (nextSong.isNetworkSource) {
      try {
        final http = await RemoteSourceService.instance
            .resolveHttpPlayback(nextSong);
        if (http != null) {
          await _rustAudioService.setReplayGainDefault(
            await _computeReplayGainDbFor(nextSong),
          );
          await _rustAudioService.queueNextHttp(
            url: http.url,
            headers: http.headers,
          );
          return;
        }
      } catch (e) {
        _debugLog('HTTP queue-next failed, falling back to cache: $e');
      }
    }

    final nextPath = await _resolveRustPath(nextSong);
    if (nextPath != null) {
      await _rustAudioService.setReplayGainDefault(
        await _computeReplayGainDbFor(nextSong),
      );
      await _rustAudioService.queueNext(nextPath);
    }
  }

  /// Resolves the next song for the just_audio crossfade engine. Mirrors the
  /// linear-next rule used by the Rust gapless path (shuffle is honoured
  /// because [_playlist] is pre-shuffled at play time). Returns null when there
  /// is no successor so the engine lets the track end naturally.
  Song? _resolveAndroidCrossfadeNext() {
    if (_playlist.isEmpty) return null;
    if (loopModeNotifier.value == LoopMode.one) return null;
    final isLastTrack = _currentIndex >= _playlist.length - 1;
    if (isLastTrack) {
      if (loopModeNotifier.value != LoopMode.all) return null;
      return _playlist[0];
    }
    return _playlist[_currentIndex + 1];
  }

  /// Called by the just_audio engine after a crossfade swap completes. The
  /// engine's emitted PlaybackState already drives currentSongNotifier, index
  /// sync, notification, replay tracking and position save via
  /// [_bindPlaybackState]; this only covers the two gaps that path leaves out.
  void _onAndroidTrackAdvanced(Song song) {
    final index = _playlist.indexWhere((entry) => entry.id == song.id);
    if (index >= 0) {
      _setCurrentIndex(index);
    }
    _consumeQueueEntryAt(_currentIndex);
    _updatePriorityAnchor();
  }

  Future<void> _savePosition({Song? song, Duration? position}) async {
    final resolvedSong = song ?? currentSongNotifier.value;
    if (!_shouldPersistSong(resolvedSong)) return;
    final persistedSong = resolvedSong!;

    try {
      await _lastPlayedService.saveLastPlayed(
        persistedSong.id,
        position ?? positionNotifier.value,
        playlistSongIds: _playlistNonQueueIds(),
        currentIndex: _currentIndex,
        wasPlaying: isPlayingNotifier.value,
      );
    } catch (e) {
      _debugLog('Failed to save last played position: $e');
    }
  }

  Future<void> persistLastPlayed() async {
    await _savePosition();
  }

  Future<void> restorePlaybackModes() async {
    final shuffleIdx = await _appPreferencesService.getShuffleMode();
    if (shuffleIdx >= 0 && shuffleIdx < ShuffleMode.values.length) {
      shuffleModeNotifier.value = ShuffleMode.values[shuffleIdx];
    }
    final loopIdx = await _appPreferencesService.getLoopMode();
    if (loopIdx >= 0 && loopIdx < LoopMode.values.length) {
      loopModeNotifier.value = LoopMode.values[loopIdx];
      await _updateLoopMode();
    }
    final advanceIdx = await _appPreferencesService.getAdvanceListOrder();
    if (advanceIdx >= 0 && advanceIdx < AdvanceListOrder.values.length) {
      _advanceListOrder = AdvanceListOrder.values[advanceIdx];
    }
    wrapAroundQueueNotifier.value = await _appPreferencesService
        .getWrapAroundQueue();
    autoplayOnQueueEndNotifier.value = await _appPreferencesService
        .getAutoplayOnQueueEnd();
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
        _debugLog(
          '[Playback] Restored ${restoredSong.title} at '
          '${lastPlayed.position.inMilliseconds}ms; waiting for explicit playback',
        );
      }
    }
  }

  Future<void> pause() {
    _debugLog('[PlayerService] pause() called');
    // Manual pause cancels any pending auto-resume from a transient focus
    // loss; otherwise the next notification's end event restarts playback.
    // The interruption handler calls _pauseInternal directly, not here.
    _wasPlayingBeforeAudioInterruption = false;
    return _enqueuePlaybackRequest(_pauseInternal);
  }

  Future<void> _pauseInternal() async {
    if (_castingService.isActive) {
      await _castingService.delegatePause();
      return;
    }
    _debugLog(
      '[Playback] pause() called, hasAttachedEngine=${_playbackManager.hasAttachedEngine}',
    );
    if (isPlayingNotifier.value) {
      isPlayingNotifier.value = false;
    }
    _updatePriorityAnchor();
    // If no engine has been attached yet (e.g. pausing a restored-but-not-started
    // track), there is nothing to pause — the optimistic update above is enough.
    if (!_playbackManager.hasAttachedEngine) {
      _debugLog(
        '[Playback] pause(): no engine attached, returning after optimistic update',
      );
      return;
    }
    try {
      await _playbackManager.pause();
    } catch (e) {
      _debugLog('Pause failed: $e');
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
    if (_castingService.isActive) {
      await _castingService.delegateResume();
      return;
    }
    await initAudio();

    final song = currentSongNotifier.value ?? _songAtCurrentIndex();
    if (song == null || song.filePath == null) {
      return;
    }

    _debugLog('[Playback] resume() called');
    // Use the cached route selection maintained by the session manager's device
    // listener rather than doing another blocking device probe on resume.
    final desiredEngine = _sessionManager.selectedMode;
    final activeEngine = await _ensureEngineReady(
      desiredEngine,
      song: song,
      reason: 'resume requested',
    );
    _debugLog('[Engine] Resume route resolved to ${activeEngine.logLabel}');

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
    _updatePriorityAnchor();
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
        normalized.contains('android usb direct') ||
        normalized.contains('usb dac disconnected') ||
        normalized.contains('usb session already active') ||
        normalized.contains('failed to claim usb interface') ||
        normalized.contains('android managed output stream') ||
        normalized.contains('sending on a disconnected channel') ||
        normalized.contains('refusing direct usb') ||
        normalized.contains('failed to set uac1 sampling frequency');
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
        normalized.contains('permission denied') ||
        normalized.contains('usb session already active');
  }

  Future<bool> _handleDirectUsbStartupRefusal(
    Object error, {
    required Song? song,
    required Duration initialPosition,
    bool autoResumeAfterFallback = true,
  }) async {
    if (!Platform.isAndroid ||
        currentEngineType != AudioEngineType.usbDacExperimental) {
      return false;
    }

    final message = error.toString();
    if (!_isDirectUsbStartupRefusal(message)) {
      return false;
    }

    _debugLog(
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
          autoPlay: autoResumeAfterFallback,
        );
      });
      _ensurePositionSaveTimer();
      await _refreshAudioOutputDiagnostics(
        reason: autoResumeAfterFallback
            ? 'direct USB fallback resumed'
            : 'direct USB fallback paused (pause-on-disconnect)',
        activeSong: song,
      );
    }

    return true;
  }

  /// Recovery for a Rust engine whose command thread died mid-session
  /// (FRB "disconnected channel" errors or a thread-crash event). The
  /// service layer already retried once against a respawned engine; if we
  /// land here the failure is persistent, so try one more explicit respawn
  /// and, failing that, fall back to the plain Android engine.
  Future<bool> _handleDeadRustEngineFailure(
    Object error, {
    required Song? song,
    required Duration initialPosition,
  }) async {
    if (!Platform.isAndroid || !_usingRustBackend) {
      return false;
    }

    final message = error.toString();
    final normalized = message.toLowerCase();
    if (!normalized.contains('disconnected channel') &&
        !normalized.contains('audio engine thread crashed')) {
      return false;
    }
    if (_deadRustEngineRecoveryActive) {
      return false;
    }

    _deadRustEngineRecoveryActive = true;
    try {
      _debugLog(
        '[Engine] Rust engine unreachable ($message); attempting respawn',
      );
      var revived = false;
      try {
        await _rustAudioService.prepareEngine();
        revived = true;
      } catch (e) {
        _debugLog('[Engine] Rust engine respawn failed: $e');
      }

      if (!revived) {
        await _rustAudioService.setHighResMode(false);
        await _sessionManager.recordFallback(
          requestedMode: currentEngineType,
          fallbackMode: AudioEngineType.normalAndroid,
          reason: 'rust audio engine unrecoverable: $message',
        );
        await _sessionManager.switchMode(
          AudioEngineType.normalAndroid,
          initializeNewEngine: true,
          reason: 'rust audio engine command channel dead',
        );
      }

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
          reason: revived
              ? 'rust engine respawned'
              : 'rust engine fallback to NORMAL_ANDROID',
          activeSong: song,
        );
      }
      return true;
    } finally {
      _deadRustEngineRecoveryActive = false;
    }
  }

  Future<void> togglePlayPause() {
    _debugLog(
      '[PlayerService] togglePlayPause called, isPlaying=${isPlayingNotifier.value}',
    );
    return _enqueuePlaybackRequest(() async {
      _debugLog(
        '[PlayerService] togglePlayPause executing, isPlaying=${isPlayingNotifier.value}',
      );
      try {
        if (isPlayingNotifier.value) {
          _wasPlayingBeforeAudioInterruption = false;
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
        _debugLog('[PlayerService] togglePlayPause error: $e\n$stack');
      }
    });
  }

  Future<void> seek(Duration position) async {
    if (_castingService.isActive) {
      await _castingService.delegateSeek(position);
      return;
    }
    try {
      await _playbackManager.seek(position);
    } catch (e) {
      _debugLog('Seek failed: $e');
    }
    unawaited(_updateNotificationState());
  }

  Future<void> next() {
    _debugLog('[PlayerService] next() called');
    return _enqueuePlaybackRequest(_nextInternal);
  }

  Future<void> _nextInternal() async {
    _debugLog(
      '[PlayerService] _nextInternal() called, playlist.length=${_playlist.length}, currentIndex=$_currentIndex',
    );
    if (_playlist.isEmpty) {
      _debugLog(
        '[PlayerService] _nextInternal: playlist is empty, returning early',
      );
      return;
    }

    _debugLog(
      'next(): currentIndex=$_currentIndex, playlistLength=${_playlist.length}, loopMode=${loopModeNotifier.value}',
    );

    if (shuffleModeNotifier.value == ShuffleMode.random &&
        _playlist.length > 1) {
      final rng = math.Random();
      int targetIndex;
      do {
        targetIndex = rng.nextInt(_playlist.length);
      } while (targetIndex == _currentIndex && _playlist.length > 1);
      _setCurrentIndex(targetIndex);
      await _playSongAtCurrentIndex();
      return;
    }

    if (_currentIndex < _playlist.length - 1) {
      final targetIndex = _currentIndex + 1;
      _setCurrentIndex(targetIndex);
      await _playSongAtCurrentIndex();
      return;
    }

    final shuffle = shuffleModeNotifier.value;
    if (shuffle == ShuffleMode.songsAndCategories ||
        shuffle == ShuffleMode.categories) {
      _debugLog(
        'next(): category shuffle active, advancing to random category',
      );
      await _advanceToRandomCategory();
      return;
    }

    if (loopModeNotifier.value == LoopMode.all) {
      _debugLog('next(): LoopMode.all, wrapping to index 0');
      _setCurrentIndex(0);
      await _playSongAtCurrentIndex();
      return;
    }

    if (loopModeNotifier.value.isAdvanceMode) {
      _debugLog(
        'next(): ${loopModeNotifier.value}, advancing to next category',
      );
      await _advanceForMode(loopModeNotifier.value);
      return;
    }

    _debugLog('next(): End of playlist');
    await _handleQueueEnd();
  }

  Future<void> previous({bool allowRestart = true}) {
    _debugLog('[PlayerService] previous() called (allowRestart=$allowRestart)');
    return _enqueuePlaybackRequest(
      () => _previousInternal(allowRestart: allowRestart),
    );
  }

  /// Swipe/slide to previous: always goes to previous track, ignoring >3s restart rule.
  /// Use this for carousel swipe gestures.
  Future<void> previousBySwipe() => previous(allowRestart: false);

  Future<void> _previousInternal({required bool allowRestart}) async {
    _debugLog(
      '[PlayerService] _previousInternal() called, playlist.length=${_playlist.length}, currentIndex=$_currentIndex, allowRestart=$allowRestart',
    );
    if (_playlist.isEmpty) {
      _debugLog(
        '[PlayerService] _previousInternal: playlist is empty, returning early',
      );
      return;
    }

    if (allowRestart && positionNotifier.value.inSeconds > 3) {
      await seek(Duration.zero);
      return;
    }

    if (_currentIndex > 0) {
      final targetIndex = _currentIndex - 1;
      _setCurrentIndex(targetIndex);
      await _playSongAtCurrentIndex();
      return;
    }

    if (wrapAroundQueue && _playlist.length > 1) {
      _setCurrentIndex(_playlist.length - 1);
      await _playSongAtCurrentIndex();
      return;
    }

    await seek(Duration.zero);
  }

  // ========== Carousel peek helpers (Poweramp-style swipe) ==========
  // Lightweight, synchronous peek into the *linear* queue order. Mirrors the
  // core of _nextInternal/_previousInternal without side-effects so the UI
  // can render adjacent stages during a drag. Shuffle random is approximated
  // linearly (heavy category/advance modes return null -> rubber-band).
  Song? get peekNext {
    if (_playlist.isEmpty) return null;
    final shuffle = shuffleModeNotifier.value;
    // Random shuffle: next is non-deterministic; approximate with linear next
    // so the user still sees a peek. Visual mismatch is preferable to no peek.
    if (shuffle == ShuffleMode.random) {
      if (_currentIndex < _playlist.length - 1) return _playlist[_currentIndex + 1];
      if (loopModeNotifier.value == LoopMode.all) return _playlist.first;
      return null;
    }
    // Category shuffles / advance modes are complex (async repo lookups);
    // peek returns linear next; commit will resolve via real _nextInternal.
    if (shuffle == ShuffleMode.categories ||
        shuffle == ShuffleMode.songsAndCategories) {
      if (_currentIndex < _playlist.length - 1) return _playlist[_currentIndex + 1];
      return null;
    }
    if (_currentIndex < _playlist.length - 1) return _playlist[_currentIndex + 1];
    if (loopModeNotifier.value == LoopMode.all) return _playlist.first;
    if (loopModeNotifier.value.isAdvanceMode) return null; // async advance
    return null;
  }

  Song? get peekPrevious {
    if (_playlist.isEmpty) return null;
    // For swipe/slide (previousBySwipe / allowRestart=false) the peek always
    // shows the previous track so the carousel can slide. For the control
    // button (allowRestart=true) the 3s restart is handled inside
    // _previousInternal and FullPlayerScreen avoids animating when it would
    // restart, so peek remains unconditional for the slide gesture.
    if (_currentIndex > 0) return _playlist[_currentIndex - 1];
    if (wrapAroundQueue && _playlist.length > 1) return _playlist.last;
    return null;
  }

  bool get hasNext => peekNext != null;
  bool get hasPrevious => peekPrevious != null;

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

      final source = await _buildAudioSources();
      _audioSourceSequence = source;

      await _runWithSuppressedSequenceStateUpdates(() async {
        await player.setAudioSource(
          _audioSourceSequence!,
          initialIndex: _currentIndex,
          initialPosition: currentPosition,
          preload: true,
        );

        await _updateLoopMode();
      });

      if (wasPlaying) {
        await player.play();
      }
    } catch (e) {
      _debugLog('Error rebuilding playlist: $e');
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
      case LoopMode.advanceAlbum:
      case LoopMode.advanceArtist:
      case LoopMode.advanceFolder:
      case LoopMode.advancePlaylist:
      case LoopMode.stopAfterCurrent:
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
    final enable = !shuffleModeNotifier.value.isActive;
    await setShuffleMode(enable ? ShuffleMode.songs : ShuffleMode.off);
  }

  Future<void> setShuffleMode(ShuffleMode mode) async {
    final wasActive = shuffleModeNotifier.value.isActive;
    shuffleModeNotifier.value = mode;
    _playedCategoryIds.clear();
    unawaited(_appPreferencesService.setShuffleMode(mode.index));

    final enable = mode.isActive;
    if (enable == wasActive) return;

    final current = currentSongNotifier.value;
    final oldCurrentIndex = _currentIndex;
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

    if (!_usingRustBackend) {
      await _syncPlaylistAfterShuffle(oldCurrentIndex: oldCurrentIndex);
    }
    await _updateNotificationState();
  }

  Future<void> _syncPlaylistAfterShuffle({required int oldCurrentIndex}) async {
    final player = _justAudioPlayer;
    final seq = _audioSourceSequence;
    if (player == null || seq == null) {
      await _rebuildPlaylist();
      return;
    }
    if (_playlist.isEmpty || _currentIndex < 0) {
      await _rebuildPlaylist();
      return;
    }
    final seqLen = seq.children.length;
    if (oldCurrentIndex < 0 || oldCurrentIndex >= seqLen) {
      await _rebuildPlaylist();
      return;
    }
    if (seqLen != _playlist.length) {
      await _rebuildPlaylist();
      return;
    }

    _isRebuildingPlaylist = true;
    try {
      final newSources = <just_audio.AudioSource>[];
      for (final song in _playlist) {
        newSources.add(await _buildAudioSourceForSong(song));
      }

      await _runWithSuppressedSequenceStateUpdates(() async {
        final int newIdx = _currentIndex;

        if (oldCurrentIndex > 0) {
          seq.removeRange(0, oldCurrentIndex);
        }
        final afterCurrent = seq.children.length - 1;
        if (afterCurrent > 0) {
          seq.removeRange(1, seq.children.length);
        }

        if (newIdx > 0) {
          seq.insertAll(0, newSources.sublist(0, newIdx));
        }
        if (newIdx + 1 < newSources.length) {
          seq.insertAll(newIdx + 1, newSources.sublist(newIdx + 1));
        }

        await _updateLoopMode();

        // Give ExoPlayer's queued index-change events time to drain while
        // suppression is still active so they don't flash the wrong song.
        await Future.delayed(const Duration(milliseconds: 50));
      });
    } finally {
      _isRebuildingPlaylist = false;
    }
  }

  static const _quickLoopCycle = [LoopMode.off, LoopMode.all, LoopMode.one];

  Future<void> toggleLoopMode() async {
    final current = loopModeNotifier.value;
    final quickIdx = _quickLoopCycle.indexOf(current);
    final next = quickIdx == -1
        ? LoopMode.off
        : _quickLoopCycle[(quickIdx + 1) % _quickLoopCycle.length];
    await setLoopMode(next);
  }

  Future<void> setLoopMode(LoopMode mode) async {
    loopModeNotifier.value = mode;
    unawaited(_appPreferencesService.setLoopMode(mode.index));
    await _updateLoopMode();
    if (!_usingRustBackend && mode == LoopMode.all) {
      await _rebuildPlaylist();
    }
  }

  // ==================== Volume ====================

  Future<void> setVolume(double volume) async {
    final tier = _determineCurrentTier();
    final tierSupportsBoost = _extendedVolumeEnabled &&
        (tier == VolumeTier.software || tier == VolumeTier.system);
    final maxForTier = tierSupportsBoost ? 2.0 : 1.0;
    final clampedVolume = volume.clamp(0.0, maxForTier).toDouble();

    if (_castingService.isActive) {
      // Cast devices cannot exceed 100 %.
      _currentVolume = clampedVolume.clamp(0.0, 1.0);
      await _castingService.delegateSetVolume(_currentVolume);
      await _reconcileSystemVolumeBoost(0.0);
      return;
    }
    _currentVolume = clampedVolume;
    if (currentEngineType == AudioEngineType.usbDacExperimental ||
        currentEngineType == AudioEngineType.dapInternalHighRes) {
      unawaited(_preferencesService.setUsbSoftwareVolume(clampedVolume));
    }

    // DoP: software gain corrupts DoP markers (0x05/0xFA).
    // Volume must go through DAC hardware exclusively.
    if (isCurrentTrackDoP && _isDirectUsbPath) {
      final mode = _uac2Service.currentDeviceStatus?.volumeMode;
      if (mode == Uac2VolumeMode.hardware && !_hwVolumeFailed) {
        _debugLog('[VolFlow] DoP HW path: uac2 setVolume($clampedVolume)');
        final hwOk = await _uac2Service.setVolume(clampedVolume);
        _onHwVolumeResult(hwOk);
      } else if (Uac2PreferencesService.autoSwitchDsdForVolumeSync &&
          clampedVolume < 1.0 &&
          _usingRustBackend &&
          _rustAudioService.isInitialized) {
        // Auto-switch to PCM for software volume control.
        // Pure DoP cannot apply software gain: it corrupts DoP markers
        // and produces silence/hiss at any level other than 100 %.
        // The only correct path is to restart the decoder in PCM decimation
        // mode, where volume works via the normal audio-callback gain loop.
        await _switchDoPForVolumeTrack(clampedVolume);
      } else {
        _debugLog(
          '[VolFlow] DoP: no hardware volume available — volume unchanged',
        );
      }
      await _reconcileSystemVolumeBoost(0.0);
      return;
    }

    _activeTier = tier;
    switch (tier) {
      case VolumeTier.hardware:
        _debugLog('[VolFlow] HW path: uac2 setVolume($clampedVolume)');
        final hwOk = await _uac2Service.setVolume(clampedVolume);
        _onHwVolumeResult(hwOk);
        if (!hwOk && !_isPassthroughActive && _usingRustBackend) {
          // Lie-detector fallback: DAC claimed hardware volume but rejected
          // the write — engine gain still works on the DSP path.
          _debugLog('[VolFlow] HW write failed — falling back to engine gain');
          await _rustAudioService.setVolume(clampedVolume);
        }
        await _reconcileSystemVolumeBoost(0.0);
        break;
      case VolumeTier.software:
        if (_usingRustBackend) {
          _debugLog('[VolFlow] SW path: engine setVolume($clampedVolume)');
          await _rustAudioService.setVolume(clampedVolume);
        }
        // No native effect on the Rust path; ensure any stale boost is released.
        await _reconcileSystemVolumeBoost(0.0);
        break;
      case VolumeTier.system:
        final player = _justAudioPlayer;
        final effective =
            math.min(clampedVolume, 1.0) * _replayGainState.linear;
        if (player != null) {
          // ExoPlayer clamps at 1.0; the boost portion (>1.0, from extended
          // volume and/or ReplayGain) is applied via Android LoudnessEnhancer.
          await player.setVolume(math.min(effective, 1.0));
        }
        await _reconcileSystemVolumeBoost(effective);
        break;
      case VolumeTier.unavailable:
        _debugLog(
          '[VolFlow] Volume unavailable (bit-perfect passthrough) — ignored',
        );
        await _reconcileSystemVolumeBoost(0.0);
        break;
    }
  }

  // ==================== ReplayGain ====================

  ReplayGainAppliedState get replayGainState => _replayGainState;

  /// Compute the effective ReplayGain (dB) for [song] from the persisted
  /// settings. 0.0 when the mode is off or tags are missing.
  Future<double> _computeReplayGainDbFor(Song song) async {
    final mode = await _appPreferencesService.getReplayGainMode();
    if (mode == ReplayGainMode.off) return 0.0;
    final preampDb = await _appPreferencesService.getReplayGainPreampDb();
    final preventClipping =
        await _appPreferencesService.getReplayGainPreventClipping();
    return computeReplayGainDbForSong(
      song,
      mode: mode,
      preampDb: preampDb,
      preventClipping: preventClipping,
    );
  }

  /// Recompute [_replayGainState] from persisted settings for [song]. When
  /// [pushSpawnDefault], also pushes the value as the spawn-time default to
  /// the Rust engine (must run before [play]/[queueNext] so the spawned
  /// source is stamped with this track's gain — the running source, if any,
  /// keeps its own gain).
  Future<void> _refreshReplayGainForSong(
    Song? song, {
    bool pushSpawnDefault = false,
  }) async {
    final mode = await _appPreferencesService.getReplayGainMode();
    if (mode == ReplayGainMode.off || song == null) {
      _replayGainState = ReplayGainAppliedState.neutral;
    } else {
      final preampDb = await _appPreferencesService.getReplayGainPreampDb();
      final preventClipping =
          await _appPreferencesService.getReplayGainPreventClipping();
      _replayGainState = ReplayGainAppliedState(
        mode: mode,
        gainDb: computeReplayGainDbForSong(
          song,
          mode: mode,
          preampDb: preampDb,
          preventClipping: preventClipping,
        ),
      );
    }
    if (pushSpawnDefault && _usingRustBackend && _rustAudioService.isInitialized) {
      try {
        await _rustAudioService.setReplayGainDefault(_replayGainState.gainDb);
      } catch (e) {
        _debugLog('[RG] default push to engine failed: $e');
      }
    }
  }

  /// Fold [_replayGainState] into the just_audio (system tier) volume and
  /// LoudnessEnhancer boost for [song].
  Future<void> _applyReplayGainForSystemTier(Song? song) async {
    await _refreshReplayGainForSong(song);
    if (_determineCurrentTier() != VolumeTier.system) return;
    final player = _justAudioPlayer;
    if (player == null) return;
    final effective =
        math.min(_currentVolume.clamp(0.0, 1.0), 1.0) * _replayGainState.linear;
    try {
      await player.setVolume(math.min(effective, 1.0));
    } catch (e) {
      _debugLog('[RG] system-volume fold failed: $e');
    }
    await _reconcileSystemVolumeBoost(effective);
  }

  /// Re-apply ReplayGain to the current track after the user changes the
  /// settings (mode / pre-amp / clipping prevention).
  Future<void> applyReplayGainFromSettings() async {
    final song = currentSongNotifier.value ??
        _playbackManager.latestState?.currentTrack;
    await _refreshReplayGainForSong(song);
    if (_usingRustBackend && _rustAudioService.isInitialized) {
      try {
        // Live update: the running source must change with the settings too.
        await _rustAudioService.setReplayGain(_replayGainState.gainDb);
      } catch (e) {
        _debugLog('[RG] live push to engine failed: $e');
      }
    }
    if (!_usingRustBackend && _determineCurrentTier() == VolumeTier.system) {
      await _applyReplayGainForSystemTier(song);
    }
  }

  /// Switch from pure DoP to PCM decimation so software volume works.
  ///
  /// Pure DoP cannot apply software gain (it corrupts DoP markers).
  /// This restarts the active DSD track's decoder in PCM decimation mode,
  /// where the normal audio-callback gain-loop handles volume cleanly.
  Future<void> _switchDoPForVolumeTrack(double volume) async {
    _debugLog('[VolFlow] DoP → PCM auto-switch for volume=$volume');

    // Persist the mode change so new DSD tracks also use PCM.
    await Uac2PreferencesService().setDsdOutputMode(DsdOutputMode.forcePcm);

    // Sync the Rust global so the next decoder spawn picks up PCM mode.
    rust_audio.audioSetDsdOutputMode(mode: 0);

    // Get current position for gapless restart.
    final progress = rust_audio.audioGetProgress();
    final posSecs = progress?.positionSecs ?? 0.0;

    // Seek restarts the decoder in the new (PCM) mode.
    await _rustAudioService.seek(
      Duration(milliseconds: (posSecs * 1000).round()),
    );

    // Volume now works via normal callback gain.
    await _rustAudioService.setVolume(volume);
    _debugLog('[VolFlow] DoP → PCM switch complete');
  }

  Future<int> addToQueue(Song song) async {
    final entry = _QueueEntry(id: _nextQueueEntryId++, song: song);
    _queuedEntries.add(entry);
    final index = _queuedEntries.length - 1;
    if (_playlist.isNotEmpty) {
      final insertIndex = (_currentIndex + 1 + _queuedEntries.length - 1).clamp(
        0,
        _playlist.length,
      );
      _playlist.insert(insertIndex, song);
      _playlistQueueEntryIds.insert(insertIndex, entry.id);

      if (!_usingRustBackend && _audioSourceSequence != null) {
        await _insertIntoAudioSequence(insertIndex, song);
      }
    }
    _notifyQueueChanged();
    _notifyUpNextChanged();
    if (!_playlist.isNotEmpty ||
        _usingRustBackend ||
        _audioSourceSequence == null) {
      _debounceQueueChanged();
    }
    return index;
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
    _notifyUpNextChanged();
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
    _notifyUpNextChanged();
    _debounceQueueChanged();
  }

  /// Clears everything after the current song: both manual queue entries
  /// and all upcoming playlist items.
  Future<void> clearAllUpcoming() async {
    // First clear manual queue entries
    _queuedEntries.clear();

    // Then remove everything after the current index from the playlist
    if (_playlist.isNotEmpty && _currentIndex >= 0) {
      final keepCount = (_currentIndex + 1).clamp(0, _playlist.length);
      if (keepCount < _playlist.length) {
        _playlist.removeRange(keepCount, _playlist.length);
        _playlistQueueEntryIds.removeRange(
          keepCount,
          _playlistQueueEntryIds.length,
        );
      }
    }

    _notifyQueueChanged();
    _notifyUpNextChanged();
    _debounceQueueChanged();
  }

  /// Removes a single song from the up-next list by its upNext-relative index.
  /// Index 0 is the first song after the currently playing song.
  Future<void> removeFromUpNext(int upNextIndex) async {
    final playlistIndex = _currentIndex + 1 + upNextIndex;
    if (playlistIndex < 0 || playlistIndex >= _playlist.length) return;

    // If this playlist slot belongs to a manual queue entry, remove that too
    final queueEntryId = _playlistQueueEntryIds[playlistIndex];
    if (queueEntryId != null) {
      _queuedEntries.removeWhere((entry) => entry.id == queueEntryId);
      _notifyQueueChanged();
    }

    _playlist.removeAt(playlistIndex);
    _playlistQueueEntryIds.removeAt(playlistIndex);
    _removeFromAudioSequence(playlistIndex);

    _notifyUpNextChanged();
    if (_usingRustBackend || _audioSourceSequence == null) {
      _debounceQueueChanged();
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
    _notifyUpNextChanged();
    _debounceQueueChanged();
  }

  Future<void> playFromUpNextIndex(int index) {
    return _enqueuePlaybackRequest(() => _playFromUpNextIndexInternal(index));
  }

  Future<void> _playFromUpNextIndexInternal(int index) async {
    final playlistIndex = _currentIndex + 1 + index;
    if (playlistIndex < 0 || playlistIndex >= _playlist.length) {
      return;
    }

    _setCurrentIndex(playlistIndex);
    await _playSongAtCurrentIndex();
  }

  Future<void> moveQueueItemToNext(int index) async {
    if (index <= 0 || index >= _queuedEntries.length) return;
    await moveQueueItem(index, 0);
  }

  Future<void> moveUpNextItem(int oldIndex, int newIndex) async {
    final upNextLength = _playlist.length - _currentIndex - 1;
    if (oldIndex < 0 ||
        oldIndex >= upNextLength ||
        newIndex < 0 ||
        newIndex >= upNextLength) {
      return;
    }
    if (oldIndex == newIndex) return;

    final playlistOldIndex = _currentIndex + 1 + oldIndex;
    var playlistNewIndex = _currentIndex + 1 + newIndex;
    if (playlistOldIndex < playlistNewIndex) playlistNewIndex -= 1;

    final song = _playlist.removeAt(playlistOldIndex);
    final entryId = _playlistQueueEntryIds.removeAt(playlistOldIndex);
    _playlist.insert(playlistNewIndex, song);
    _playlistQueueEntryIds.insert(playlistNewIndex, entryId);

    _notifyUpNextChanged();
    _debounceQueueChanged();
  }

  // ==================== Playback Speed ====================

  Future<void> setPlaybackSpeed(double speed) async {
    final clampedSpeed = speed.clamp(0.5, 2.0).toDouble();
    if (isBitPerfectProcessingLocked) {
      _debugLog(
        '[Playback] Ignoring playback-speed change while Bit-perfect (USB DAC) is enabled',
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

  // ==================== Pitch Shift ====================

  Future<void> setPitchSemitones(double semitones) async {
    final clamped = semitones.clamp(-12.0, 12.0).toDouble();
    debugPrint(
      '[PITCH] setPitchSemitones($semitones) -> clamped=$clamped, '
      'usingRustBackend=$_usingRustBackend, '
      'bitPerfectLocked=$isBitPerfectProcessingLocked',
    );
    if (isBitPerfectProcessingLocked) {
      _debugLog(
        '[Playback] Ignoring pitch-shift change while Bit-perfect (USB DAC) is enabled',
      );
      if (_usingRustBackend) {
        await _rustAudioService.setPitchShiftSemitones(0.0);
      } else {
        final player = _justAudioPlayer;
        if (player != null) {
          await player.setPitch(1.0);
        }
      }
      return;
    }
    pitchSemitonesNotifier.value = clamped;
    if (_usingRustBackend) {
      await _rustAudioService.setPitchShiftSemitones(clamped);
    } else {
      final player = _justAudioPlayer;
      if (player != null) {
        // ponytail: just_audio setPitch takes a frequency ratio (1.0 = no shift).
        final ratio = math.pow(2, clamped / 12).toDouble();
        await player.setPitch(ratio);
      }
    }
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

  void _armAutoSyncGuard(Song song) {
    _autoSyncGuardSongId = song.id;
  }

  void _clearAutoSyncGuard() {
    _autoSyncGuardSongId = null;
  }

  void _checkPlaybackDesync(PlaybackState state) {
    final engineTrack = state.currentTrack;
    _engineCurrentTrack = engineTrack;

    final uiSong = currentSongNotifier.value;

    if (engineTrack == null) {
      _desyncDetectionTimer?.cancel();
      _desyncDetectionTimer = null;
      if (playbackDesyncedNotifier.value) {
        playbackDesyncedNotifier.value = false;
      }
      return;
    }

    if (uiSong != null && uiSong.id == engineTrack.id) {
      _desyncDetectionTimer?.cancel();
      _desyncDetectionTimer = null;
      if (playbackDesyncedNotifier.value) {
        playbackDesyncedNotifier.value = false;
      }
      return;
    }

    if (_desyncDetectionTimer != null) return;

    _desyncDetectionTimer = Timer(_desyncThreshold, () {
      if (_engineCurrentTrack != null &&
          currentSongNotifier.value?.id != _engineCurrentTrack!.id) {
        playbackDesyncedNotifier.value = true;
      }
    });
  }

  void syncNow() {
    _desyncDetectionTimer?.cancel();
    _desyncDetectionTimer = null;
    playbackDesyncedNotifier.value = false;

    final engineTrack = _engineCurrentTrack;
    if (engineTrack == null) return;

    currentSongNotifier.value = engineTrack;
    _syncCurrentIndexToTrack(engineTrack);
    _syncUac2PlaybackStatus(engineTrack, isPlaying: isPlayingNotifier.value);
    _updateNotificationState();
  }

  void _ensurePositionSaveTimer() {
    _positionSaveTimer?.cancel();
    _positionSaveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _savePosition();
      _maybePrefetchNextNetworkSong();
    });
  }

  /// Last song id handed to [RemoteSourceService.prefetch]. Reset whenever the
  /// current track changes so a replayed song re-prefetches its successor.
  String? _prefetchedNextSongId;

  /// P1.7: when the current network-sourced track is within 10s of its end,
  /// start downloading the linear-next song so gapless/crossfade handoff reads
  /// a local path. Cache hits make repeated calls no-ops (and the marker is
  /// reset on track change, which also covers wrap-around).
  void _maybePrefetchNextNetworkSong() {
    final current = currentSongNotifier.value;
    if (current == null || !current.isNetworkSource) return;
    if (_playlist.isEmpty || _currentIndex < 0) return;

    final duration = durationNotifier.value;
    if (duration <= Duration.zero) return;
    if (positionNotifier.value < duration - const Duration(seconds: 10)) {
      return;
    }

    if (_currentIndex >= _playlist.length - 1 &&
        loopModeNotifier.value != LoopMode.all) {
      return;
    }
    final nextIndex = _currentIndex >= _playlist.length - 1
        ? 0
        : _currentIndex + 1;
    final next = _playlist[nextIndex];
    if (!next.isNetworkSource) return;
    if (next.id == _prefetchedNextSongId) return;

    _prefetchedNextSongId = next.id;
    unawaited(RemoteSourceService.instance.prefetch(next));
  }

  void _startHwVolumeHealthTimer() {
    _hwVolumeHealthTimer?.cancel();
    _hwVolumeHealthTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _checkHwVolumeHealth(),
    );
  }

  void _stopHwVolumeHealthTimer() {
    _hwVolumeHealthTimer?.cancel();
    _hwVolumeHealthTimer = null;
  }

  Future<void> _checkHwVolumeHealth() async {
    if (_activeTier != VolumeTier.hardware) return;
    final healthy = await _uac2Service.verifyHardwareVolumeHealth();
    if (healthy == false) {
      _debugLog(
        '[VolFlow] HW volume health check failed — falling back to software tier',
      );
      _onHwVolumeResult(false);
    }
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
    _playbackDiagnosticsDebounceTimer?.cancel();
    _playbackDiagnosticsDebounceTimer = null;
    _queueDebounceTimer?.cancel();
    _positionSaveTimer?.cancel();
    _stopHwVolumeHealthTimer();
    unawaited(_audioFocusSubscription?.cancel());
    unawaited(_bluetoothDeviceEventSubscription?.cancel());
    unawaited(_usbDacDetachSubscription?.cancel());
    unawaited(_usbDacAttachSubscription?.cancel());
    cancelSleepTimer();
    _notificationService.hideNotification();
    _floatingPlayerService.hide();
    if (_usingRustBackend) {
      if (Uac2PreferencesService.isKillIsochronousUsbOnQuitSync) {
        unawaited(_rustAudioService.stop());
      }
    }

    final player = _justAudioPlayer;
    if (player != null) {
      unawaited(player.dispose());
      _justAudioPlayer = null;
    }
    _playbackStateSubscription?.cancel();
    unawaited(_playbackManager.dispose());
    selectedPlaybackModeNotifier.removeListener(
      _updateBitPerfectProcessingLocked,
    );
    initializedPlaybackModeNotifier.removeListener(
      _updateBitPerfectProcessingLocked,
    );
    _uac2Service.bitPerfectEnabledNotifier.removeListener(
      _updateBitPerfectProcessingLocked,
    );
    _uac2Service.dapBitPerfectEnabledNotifier.removeListener(
      _updateBitPerfectProcessingLocked,
    );
    Uac2PreferencesService.tuning432HzNotifier.removeListener(
      _on432HzTuningChanged,
    );
    if (_bitPerfectLockedListener != null) {
      bitPerfectProcessingLockedNotifier.removeListener(
        _bitPerfectLockedListener!,
      );
    }
    _sessionManager.dispose();
    audioOutputDiagnosticsNotifier.dispose();
    bitPerfectProcessingLockedNotifier.dispose();

    currentSongNotifier.dispose();
    isPlayingNotifier.dispose();
    positionNotifier.dispose();
    durationNotifier.dispose();
    bufferedPositionNotifier.dispose();
    isNetworkLoadingNotifier.dispose();
    playbackSpeedNotifier.dispose();
    pitchSemitonesNotifier.dispose();
    sleepTimerRemainingNotifier.dispose();

    for (final stagedPath in _stagedPlaybackPathCache.values) {
      unawaited(_deleteTemporaryPlaybackFile(stagedPath));
    }
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
      _debugLog('Failed to delete temporary playback file: $e');
    }
  }

  // ─── Playback Context ──────────────────────────────────────────────

  void setPlaybackContext(PlaybackContext context) {
    _playbackContext = context;
    playbackContextNotifier.value = context;
    if (context.sourceId != null &&
        context.source != PlaybackSource.unknown &&
        context.source != PlaybackSource.allSongs) {
      _playedCategoryIds.add(context.sourceId!);
    }
  }

  // ─── Advance List ──────────────────────────────────────────────────

  void setAdvanceListOrder(AdvanceListOrder order) {
    _advanceListOrder = order;
    unawaited(_appPreferencesService.setAdvanceListOrder(order.index));
  }

  void setWrapAroundQueue(bool value) {
    wrapAroundQueueNotifier.value = value;
    unawaited(_appPreferencesService.setWrapAroundQueue(value));
  }

  void setAutoplayOnQueueEnd(bool value) {
    autoplayOnQueueEndNotifier.value = value;
    unawaited(_appPreferencesService.setAutoplayOnQueueEnd(value));
  }

  // ponytail: at a genuine queue end (loop off, no advance/shuffle left),
  // autoplay a random library track instead of stopping. Mirrors the
  // "autoplay" behaviour of mainstream players. Falls back to pause+rewind
  // when disabled, the library is empty, or the only song is the current one.
  Future<void> _handleQueueEnd() async {
    if (autoplayOnQueueEndNotifier.value) {
      try {
        final allSongs = await _songRepository.getAllSongs();
        final currentId = currentSongNotifier.value?.id;
        final candidates =
            allSongs.where((s) => s.id != currentId).toList();
        if (candidates.isNotEmpty) {
          final rng = math.Random();
          await _playInternal(
            candidates[rng.nextInt(candidates.length)],
            playlist: allSongs,
          );
          return;
        }
      } catch (e) {
        _debugLog('_handleQueueEnd autoplay error: $e');
      }
    }
    await _pauseInternal();
    await seek(Duration.zero);
  }

  Future<void> _advanceForMode(LoopMode mode) async {
    final song = currentSongNotifier.value;
    if (song == null) {
      await _handleQueueEnd();
      return;
    }

    try {
      final List<Song>? nextSongs;
      switch (mode) {
        case LoopMode.advanceAlbum:
          nextSongs = await _getNextAlbumSongs(song.album);
        case LoopMode.advanceArtist:
          nextSongs = await _getNextArtistSongs(song.artist);
        case LoopMode.advanceFolder:
          nextSongs = await _getNextFolderSongs(song.folderUri);
        case LoopMode.advancePlaylist:
          nextSongs = await _getNextPlaylistSongs(_playbackContext.sourceId);
        default:
          nextSongs = null;
      }

      if (nextSongs == null || nextSongs.isEmpty) {
        _debugLog('_advanceForMode($mode): no next category found');
        await _handleQueueEnd();
        return;
      }
      await _playInternal(nextSongs.first, playlist: nextSongs);
    } catch (e) {
      _debugLog('_advanceForMode($mode): error: $e');
      await _handleQueueEnd();
    }
  }

  Future<List<Song>?> _getNextAlbumSongs(String? currentAlbum) async {
    if (currentAlbum == null) return null;
    final groups = await _songRepository.getAlbumGroups();
    if (groups.isEmpty) return null;
    final sorted = _sortCategories(groups.map((g) => g.albumName).toList());
    final nextName = _pickNext(sorted, currentAlbum);
    if (nextName == null) return null;
    final nextGroup = groups.firstWhere((g) => g.albumName == nextName);
    setPlaybackContext(
      PlaybackContext(
        source: PlaybackSource.album,
        sourceId: nextName,
        sourceName: nextName,
      ),
    );
    return nextGroup.songs;
  }

  Future<List<Song>?> _getNextArtistSongs(String? currentArtist) async {
    if (currentArtist == null) return null;
    final artistMap = await _songRepository.getSongsByArtist();
    if (artistMap.isEmpty) return null;
    final sorted = _sortCategories(artistMap.keys.toList());
    final nextName = _pickNext(sorted, currentArtist);
    if (nextName == null) return null;
    setPlaybackContext(
      PlaybackContext(
        source: PlaybackSource.artist,
        sourceId: nextName,
        sourceName: nextName,
      ),
    );
    return artistMap[nextName];
  }

  Future<List<Song>?> _getNextFolderSongs(String? currentUri) async {
    if (currentUri == null) return null;
    final uris = await _songRepository.getUniqueFolderUris();
    if (uris.isEmpty) return null;
    final sorted = _sortCategories(uris);
    final nextUri = _pickNext(sorted, currentUri);
    if (nextUri == null) return null;
    final songs = await _songRepository.getSongsByFolder(nextUri);
    if (songs.isEmpty) return null;
    final folderName =
        Uri.tryParse(nextUri)?.pathSegments.lastOrNull ?? nextUri;
    setPlaybackContext(
      PlaybackContext(
        source: PlaybackSource.folder,
        sourceId: nextUri,
        sourceName: folderName,
      ),
    );
    return songs;
  }

  Future<List<Song>?> _getNextPlaylistSongs(String? currentId) async {
    if (currentId == null) return null;
    final playlists = await _playlistService.getPlaylists();
    if (playlists.isEmpty) return null;
    final sorted = _sortCategories(playlists.map((p) => p.id).toList());
    final nextId = _pickNext(sorted, currentId);
    if (nextId == null) return null;
    final playlist = playlists.firstWhere((p) => p.id == nextId);
    final allSongs = await _songRepository.getAllSongs();
    final songIdSet = playlist.songIds.toSet();
    final songs = allSongs.where((s) => songIdSet.contains(s.id)).toList();
    if (songs.isEmpty) return null;
    setPlaybackContext(
      PlaybackContext(
        source: PlaybackSource.playlist,
        sourceId: nextId,
        sourceName: playlist.name,
      ),
    );
    return songs;
  }

  List<String> _sortCategories(List<String> items) {
    switch (_advanceListOrder) {
      case AdvanceListOrder.alphabetical:
        return List.of(items)
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      case AdvanceListOrder.dateAdded:
        return items;
      case AdvanceListOrder.random:
        return List.of(items)..shuffle(math.Random());
    }
  }

  String? _pickNext(List<String> sorted, String current) {
    if (sorted.isEmpty) return null;
    final idx = sorted.indexOf(current);
    if (idx == -1) return sorted.first;
    if (idx >= sorted.length - 1) return null;
    return sorted[idx + 1];
  }

  Future<void> _advanceToRandomCategory() async {
    final ctx = _playbackContext;
    if (ctx.source == PlaybackSource.unknown ||
        ctx.source == PlaybackSource.allSongs) {
      await _handleQueueEnd();
      return;
    }

    try {
      final allIds = await _getAllCategoryIds(ctx.source);
      var available = allIds
          .where((id) => !_playedCategoryIds.contains(id))
          .toList();

      if (available.isEmpty) {
        if (loopModeNotifier.value == LoopMode.all) {
          _playedCategoryIds.clear();
          if (ctx.sourceId != null) _playedCategoryIds.add(ctx.sourceId!);
          available = allIds
              .where((id) => !_playedCategoryIds.contains(id))
              .toList();
        }
        if (available.isEmpty) {
          await _handleQueueEnd();
          return;
        }
      }

      final rng = math.Random();
      final nextId = available[rng.nextInt(available.length)];
      final songs = await _getCategorySongsById(ctx.source, nextId);
      if (songs == null || songs.isEmpty) {
        await _handleQueueEnd();
        return;
      }

      final shouldShuffle =
          shuffleModeNotifier.value == ShuffleMode.songsAndCategories;
      final ordered = shouldShuffle
          ? (List<Song>.of(songs)..shuffle(rng))
          : songs;
      await _playInternal(ordered.first, playlist: ordered);
    } catch (e) {
      _debugLog('_advanceToRandomCategory error: $e');
      await _handleQueueEnd();
    }
  }

  Future<List<String>> _getAllCategoryIds(PlaybackSource source) async {
    switch (source) {
      case PlaybackSource.album:
        final groups = await _songRepository.getAlbumGroups();
        return groups.map((g) => g.albumName).toList();
      case PlaybackSource.artist:
        final artistMap = await _songRepository.getSongsByArtist();
        return artistMap.keys.toList();
      case PlaybackSource.folder:
        return _songRepository.getUniqueFolderUris();
      case PlaybackSource.playlist:
        final playlists = await _playlistService.getPlaylists();
        return playlists.map((p) => p.id).toList();
      case PlaybackSource.allSongs:
      case PlaybackSource.network:
      case PlaybackSource.unknown:
        return [];
    }
  }

  Future<List<Song>?> _getCategorySongsById(
    PlaybackSource source,
    String id,
  ) async {
    switch (source) {
      case PlaybackSource.album:
        final groups = await _songRepository.getAlbumGroups();
        final group = groups.where((g) => g.albumName == id).firstOrNull;
        if (group == null) return null;
        setPlaybackContext(
          PlaybackContext(
            source: PlaybackSource.album,
            sourceId: id,
            sourceName: id,
          ),
        );
        return group.songs;
      case PlaybackSource.artist:
        final artistMap = await _songRepository.getSongsByArtist();
        final songs = artistMap[id];
        if (songs == null) return null;
        setPlaybackContext(
          PlaybackContext(
            source: PlaybackSource.artist,
            sourceId: id,
            sourceName: id,
          ),
        );
        return songs;
      case PlaybackSource.folder:
        final songs = await _songRepository.getSongsByFolder(id);
        if (songs.isEmpty) return null;
        final folderName = Uri.tryParse(id)?.pathSegments.lastOrNull ?? id;
        setPlaybackContext(
          PlaybackContext(
            source: PlaybackSource.folder,
            sourceId: id,
            sourceName: folderName,
          ),
        );
        return songs;
      case PlaybackSource.playlist:
        final playlist = await _playlistService.getPlaylist(id);
        if (playlist == null) return null;
        final allSongs = await _songRepository.getAllSongs();
        final songIdSet = playlist.songIds.toSet();
        final songs = allSongs.where((s) => songIdSet.contains(s.id)).toList();
        if (songs.isEmpty) return null;
        setPlaybackContext(
          PlaybackContext(
            source: PlaybackSource.playlist,
            sourceId: id,
            sourceName: playlist.name,
          ),
        );
        return songs;
      case PlaybackSource.allSongs:
      case PlaybackSource.network:
      case PlaybackSource.unknown:
        return null;
    }
  }

  // ─── A-B Repeat ────────────────────────────────────────────────────

  void setAbRepeatA() {
    abRepeatANotifier.value = positionNotifier.value;
  }

  void setAbRepeatB() {
    final b = positionNotifier.value;
    final a = abRepeatANotifier.value;
    if (a == null || b <= a) return;
    abRepeatBNotifier.value = b;
  }

  void clearAbRepeat() {
    abRepeatANotifier.value = null;
    abRepeatBNotifier.value = null;
  }

  bool get isAbRepeatActive =>
      abRepeatANotifier.value != null && abRepeatBNotifier.value != null;

  void checkAbRepeatBoundary(Duration position) {
    final a = abRepeatANotifier.value;
    final b = abRepeatBNotifier.value;
    if (a == null || b == null) return;
    if (position >= b) {
      seek(a);
    }
  }
}

class _QueueEntry {
  final int id;
  final Song song;

  const _QueueEntry({required this.id, required this.song});
}

class _MutableValueNotifier<T> extends ValueNotifier<T> {
  _MutableValueNotifier(super.value) : _currentValue = value;

  T _currentValue;

  @override
  T get value => _currentValue;

  @override
  set value(T newValue) {
    if (identical(_currentValue, newValue)) {
      return;
    }
    _currentValue = newValue;
    notifyListeners();
  }
}

class _ShuffleBoolNotifier extends ValueNotifier<bool> {
  _ShuffleBoolNotifier(this._source) : super(_source.value.isActive) {
    _source.addListener(_sync);
  }

  final ValueNotifier<ShuffleMode> _source;

  void _sync() {
    final active = _source.value.isActive;
    if (value != active) {
      value = active;
    }
  }

  @override
  set value(bool newValue) {
    super.value = newValue;
    if (newValue && !_source.value.isActive) {
      _source.value = ShuffleMode.songs;
    } else if (!newValue && _source.value.isActive) {
      _source.value = ShuffleMode.off;
    }
  }

  @override
  void dispose() {
    _source.removeListener(_sync);
    super.dispose();
  }
}
