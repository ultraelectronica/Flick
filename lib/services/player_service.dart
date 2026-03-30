import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:flick/models/song.dart';
import 'package:flick/services/notification_service.dart';
import 'package:flick/services/last_played_service.dart';
import 'package:flick/services/favorites_service.dart';
import 'package:flick/data/repositories/recently_played_repository.dart';
import 'package:flick/services/equalizer_service.dart';
import 'package:flick/services/replay_play_tracker.dart';
import 'package:flick/services/rust_audio_service.dart';
import 'package:flick/services/uac2_service.dart';
import 'package:flick/services/alac_converter_service.dart';

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
  final RustAudioService _rustAudioService = RustAudioService();
  final Uac2Service _uac2Service = Uac2Service.instance;
  final RecentlyPlayedRepository _recentlyPlayedRepository =
      RecentlyPlayedRepository();
  final ReplayPlayTracker _replayPlayTracker = ReplayPlayTracker();
  static const MethodChannel _storageChannel = MethodChannel(
    'com.ultraelectronica.flick/storage',
  );
  final Map<String, String> _stagedPlaybackPathCache = {};
  final Map<String, String> _convertedPlaybackPathCache = {};
  bool _usingRustBackend = false;
  bool _rustBackendAvailable = false;
  bool _justAudioListenersAttached = false;
  bool _rustListenersAttached = false;
  bool _audioInitialized = false;
  Future<void>? _audioInitInFlight;
  Future<bool>? _rustInitInFlight;
  bool _suppressSequenceStateUpdates = false;
  DateTime? _autoSyncGuardUntil;
  String? _autoSyncGuardSongId;

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
  List<Song> get upNext {
    if (_playlist.isEmpty) return const [];
    final startIndex = (_currentIndex + 1).clamp(0, _playlist.length);
    return List.unmodifiable(_playlist.sublist(startIndex));
  }

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
  int? get androidAudioSessionId => _justAudioPlayer.androidAudioSessionId;

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

  Future<void> _initializeAudio() async {
    debugPrint('Initializing just_audio with gapless playback support');

    try {
      _setupJustAudioListeners();
      _setupRustAudioListeners();
      await _updateLoopMode();
      _audioInitialized = true;

      unawaited(
        _uac2Service.initialize().catchError(
          (Object e) => debugPrint('UAC2 init failed: $e'),
        ),
      );
    } finally {
      _audioInitInFlight = null;
    }
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

  Future<bool> _waitForRustPlaybackStart({
    Duration timeout = const Duration(milliseconds: 1500),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final state = _rustAudioService.stateNotifier.value;
      if (state == RustPlaybackState.playing ||
          state == RustPlaybackState.crossfading ||
          state == RustPlaybackState.buffering ||
          state == RustPlaybackState.paused) {
        return true;
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }
    return false;
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

    _justAudioPlayer.errorStream.listen((error) {
      if (_usingRustBackend) return;
      final song = currentSongNotifier.value;
      if (song == null) return;

      debugPrint('just_audio error for ${song.title}: $error');
      unawaited(_tryRustFallbackPlayback(song, force: true));
    });

    _justAudioPlayer.playerStateStream.listen((state) {
      if (_usingRustBackend) return;
      final wasPlaying = isPlayingNotifier.value;
      isPlayingNotifier.value = state.playing;
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
          state.processingState == just_audio.ProcessingState.completed) {
        _onSongFinished();
      }
    });

    _justAudioPlayer.positionStream.listen((pos) {
      if (_usingRustBackend) return;
      if (!_suppressSequenceStateUpdates) {
        final activeIndex = _justAudioPlayer.currentIndex;
        if (activeIndex != null && activeIndex != _currentIndex) {
          _syncCurrentSongFromIndex(activeIndex, fromListener: true);
        }
      }

      // When repeat-one loops, just_audio may not fire completed; detect
      // position wrapping back to start so the notification progress bar resets.
      final prev = _lastPosition;
      _lastPosition = pos;
      positionNotifier.value = pos;
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
    });

    _justAudioPlayer.bufferedPositionStream.listen((pos) {
      if (_usingRustBackend) return;
      bufferedPositionNotifier.value = pos;
    });

    _justAudioPlayer.durationStream.listen((dur) {
      if (_usingRustBackend) return;
      if (dur != null) {
        durationNotifier.value = dur;
        if (currentSongNotifier.value != null && isPlayingNotifier.value) {
          _updateNotificationState();
        }
      }
    });

    // Listen to sequence state changes for gapless transitions
    _justAudioPlayer.sequenceStateStream.listen((sequenceState) {
      if (_usingRustBackend) return;
      // Skip updates during playlist rebuild to prevent wrong song display
      if (_isRebuildingPlaylist || _suppressSequenceStateUpdates) return;

      if (sequenceState.currentIndex != null) {
        _syncCurrentSongFromIndex(
          sequenceState.currentIndex!,
          fromListener: true,
        );
      }
    });

    // Some engines/transition paths may emit currentIndex without a matching
    // sequenceState transition callback timing. Keep UI in sync either way.
    _justAudioPlayer.currentIndexStream.listen((newIndex) {
      if (_usingRustBackend) return;
      if (_isRebuildingPlaylist || _suppressSequenceStateUpdates) return;
      if (newIndex == null) return;
      _syncCurrentSongFromIndex(newIndex, fromListener: true);
    });

    _justAudioPlayer.positionDiscontinuityStream.listen((discontinuity) {
      if (_usingRustBackend) return;
      if (_isRebuildingPlaylist || _suppressSequenceStateUpdates) return;
      if (discontinuity.reason !=
          just_audio.PositionDiscontinuityReason.autoAdvance) {
        return;
      }

      final newIndex = discontinuity.event.currentIndex;
      if (newIndex == null) return;
      _syncCurrentSongFromIndex(newIndex, fromListener: true);
    });
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
      currentSongNotifier.value = newSong;
      _startReplayTracking(newSong);
      positionNotifier.value = Duration.zero;
      unawaited(_savePosition());
      unawaited(
        _syncUac2PlaybackStatus(newSong, isPlaying: isPlayingNotifier.value),
      );
      _updateNotificationState();
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

    _rustAudioService.stateNotifier.addListener(() {
      if (!_usingRustBackend) return;

      final rustState = _rustAudioService.stateNotifier.value;
      final isPlaying =
          rustState == RustPlaybackState.playing ||
          rustState == RustPlaybackState.crossfading;

      isPlayingNotifier.value = isPlaying;
      unawaited(
        _syncUac2PlaybackStatus(
          currentSongNotifier.value,
          isPlaying: isPlaying,
        ),
      );
    });

    _rustAudioService.positionNotifier.addListener(() {
      if (!_usingRustBackend) return;

      positionNotifier.value = _rustAudioService.positionNotifier.value;
      _trackReplayProgress(positionNotifier.value);

      final now = DateTime.now();
      if (currentSongNotifier.value != null &&
          isPlayingNotifier.value &&
          now.difference(_lastNotificationUpdate).inSeconds >= 2) {
        _lastNotificationUpdate = now;
        _updateNotificationState();
      }
    });

    _rustAudioService.durationNotifier.addListener(() {
      if (!_usingRustBackend) return;
      durationNotifier.value = _rustAudioService.durationNotifier.value;
    });

    _rustAudioService.onTrackEnded = (_) {
      if (!_usingRustBackend) return;
      _onSongFinished();
    };
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

    if (_usingRustBackend) {
      await _rustAudioService.stop();
      isPlayingNotifier.value = false;
      positionNotifier.value = Duration.zero;
      bufferedPositionNotifier.value = Duration.zero;
    } else {
      await _justAudioPlayer.pause();
      await _justAudioPlayer.seek(Duration.zero);
    }

    cancelSleepTimer();
    await _syncUac2PlaybackStatus(null, isPlaying: false);
    _notificationService.hideNotification();
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
    final filePath = song.filePath;
    if (filePath == null || filePath.isEmpty) {
      return Uri.parse('');
    }

    final sourceKey = filePath;
    String resolvedPath = filePath;

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
        return Uri.file(convertedPath);
      }
    }

    return _toPlaybackUri(resolvedPath);
  }

  bool _shouldStageForPlayback(Song song) {
    final normalized = song.fileType.replaceAll('.', '').trim().toUpperCase();
    if (normalized == 'ALAC' || normalized == 'AIFF' || normalized == 'AIF') {
      return true;
    }

    // M4A can be either AAC (usually fine) or ALAC. Use resolution metadata as
    // a proxy to avoid staging every AAC M4A in large playlists.
    if (normalized == 'M4A') {
      final resolution = song.resolution?.toLowerCase() ?? '';
      return resolution.contains('-bit');
    }

    return false;
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
    final fileType = song.fileType.replaceAll('.', '').trim().toLowerCase();
    if (fileType == 'aiff' || fileType == 'aif') return 'aiff';
    if (fileType == 'alac' || fileType == 'm4a') return 'm4a';
    if (RegExp(r'^[a-z0-9]+$').hasMatch(fileType) && fileType.isNotEmpty) {
      return fileType;
    }

    final filePath = song.filePath;
    if (filePath != null) {
      final extension = _extractExtension(filePath);
      if (extension.isNotEmpty) {
        return extension;
      }
    }
    return 'm4a';
  }

  String _extractExtension(String path) {
    final withoutQuery = path.split('?').first;
    final dotIndex = withoutQuery.lastIndexOf('.');
    if (dotIndex < 0 || dotIndex >= withoutQuery.length - 1) return '';
    return withoutQuery.substring(dotIndex + 1).toLowerCase();
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
    final normalized = song.fileType.replaceAll('.', '').trim().toUpperCase();
    return normalized == 'AIFF' || normalized == 'AIF';
  }

  Future<String?> _convertPlaybackPathToWav({
    required String sourceKey,
    required String sourcePath,
  }) async {
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

    try {
      final convertedPath = await AlacConverterService.convertToWavFile(
        playbackUri.toFilePath(),
      );
      _convertedPlaybackPathCache[sourceKey] = convertedPath;
      return convertedPath;
    } catch (e) {
      debugPrint('Failed to convert playback path to WAV: $e');
      return null;
    }
  }

  bool _requiresRustFormatFallback(Song song) {
    final normalized = song.fileType.replaceAll('.', '').trim().toUpperCase();
    return normalized == 'ALAC' || normalized == 'M4A';
  }

  Future<bool> _shouldPreferRustBackend(Song song) async {
    if (_requiresRustFormatFallback(song)) {
      return true;
    }

    if (!Platform.isAndroid) {
      return false;
    }

    return _uac2Service.isAndroidExternalUsbRouteActive();
  }

  Future<String?> _resolveRustPath(Song song) async {
    final filePath = song.filePath;
    if (filePath == null || filePath.isEmpty) return null;

    final parsed = Uri.tryParse(filePath);
    if (parsed?.scheme == 'content') {
      return _stageContentUriForPlayback(
        filePath,
        extensionHint: _preferredExtension(song),
      );
    }

    final uri = _toPlaybackUri(filePath);
    if (uri.scheme == 'file') {
      return uri.toFilePath();
    }

    if (uri.scheme.isEmpty) {
      return filePath;
    }

    return null;
  }

  Future<bool> _tryRustFallbackPlayback(Song song, {bool force = false}) async {
    if (!force && !await _shouldPreferRustBackend(song)) {
      return false;
    }

    final rustAvailable = await _ensureRustBackendAvailable();
    if (!rustAvailable) {
      return false;
    }

    final path = await _resolveRustPath(song);
    if (path == null || path.isEmpty) {
      debugPrint('Rust fallback skipped: failed to resolve playable path');
      return false;
    }

    try {
      _usingRustBackend = true;
      await _justAudioPlayer.stop();
      await _uac2Service.syncPlaybackStatus(
        song: song,
        isPlaying: false,
        formatOverride: _deriveUac2FormatFromSong(song),
      );
      await _rustAudioService.play(path);

      final started = await _waitForRustPlaybackStart();
      if (!started) {
        throw StateError('Rust playback did not start within timeout');
      }

      final rustState = _rustAudioService.stateNotifier.value;
      isPlayingNotifier.value =
          rustState == RustPlaybackState.playing ||
          rustState == RustPlaybackState.crossfading;
      positionNotifier.value = Duration.zero;
      durationNotifier.value =
          _rustAudioService.durationNotifier.value > Duration.zero
          ? _rustAudioService.durationNotifier.value
          : song.duration;
      bufferedPositionNotifier.value = Duration.zero;
      await _rustAudioService.setPlaybackSpeed(playbackSpeedNotifier.value);
      await _rustAudioService.setVolume(_rustAudioService.volumeNotifier.value);
      await _rustAudioService.setCrossfade(
        enabled: _rustAudioService.crossfadeEnabledNotifier.value,
        durationSecs: _rustAudioService.crossfadeDurationNotifier.value,
      );
      await reapplyEqualizer();
      unawaited(_updateNotificationState());
      unawaited(
        _syncUac2PlaybackStatus(song, isPlaying: isPlayingNotifier.value),
      );

      _positionSaveTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _savePosition(),
      );

      debugPrint('Using Rust fallback backend for ${song.title} @ $path');
      return true;
    } catch (e) {
      _usingRustBackend = false;
      try {
        await _rustAudioService.stop();
      } catch (_) {}
      debugPrint('Rust fallback playback failed: $e');
      return false;
    }
  }

  /// Play a specific song.
  Future<void> play(Song song, {List<Song>? playlist}) async {
    await initAudio();

    try {
      await _runWithSuppressedSequenceStateUpdates(() async {
        _positionSaveTimer?.cancel();

        if (_usingRustBackend) {
          await _rustAudioService.stop();
          _usingRustBackend = false;
        } else {
          await _justAudioPlayer.stop();
        }

        if (playlist != null) {
          _replacePlaybackContext(playlist);
          _setCurrentIndex(_playlist.indexOf(song));
          _insertQueuedEntriesAfterCurrent();
        } else {
          if (!_playlist.contains(song)) {
            _replacePlaybackContext([song]);
            _setCurrentIndex(0);
            _insertQueuedEntriesAfterCurrent();
          } else {
            _setCurrentIndex(_playlist.indexOf(song));
          }
        }

        currentSongNotifier.value = song;
        _armAutoSyncGuard(song);
        _startReplayTracking(song);

        positionNotifier.value = Duration.zero;
        durationNotifier.value = song.duration;
        unawaited(_savePosition());

        if (song.filePath != null) {
          // Prefer the native backend for USB DAC playback and for formats that
          // are unreliable on the platform decoder stack.
          if (await _shouldPreferRustBackend(song)) {
            final usedRust = await _tryRustFallbackPlayback(song, force: true);
            if (usedRust) {
              return;
            }
            debugPrint(
              'Rust preferred backend failed for ${song.title}; trying just_audio',
            );
          }

          // Build audio sources for gapless playback
          final sources = await _buildAudioSources();

          await _justAudioPlayer.setAudioSources(
            sources,
            initialIndex: _currentIndex,
            preload: true, // Enable gapless playback by preloading next track
          );
          await _justAudioPlayer.setSpeed(playbackSpeedNotifier.value);
          await _updateLoopMode();
          await _justAudioPlayer.play();
          await reapplyEqualizer();
          unawaited(_updateNotificationState());
          unawaited(_syncUac2PlaybackStatus(song, isPlaying: true));

          _positionSaveTimer = Timer.periodic(
            const Duration(seconds: 5),
            (_) => _savePosition(),
          );
        }
      });
    } catch (e) {
      debugPrint("Error playing song with just_audio: $e");
      final usedRustFallback = await _tryRustFallbackPlayback(
        song,
        force: true,
      );
      if (!usedRustFallback) {
        debugPrint("Playback failed on both backends for ${song.title}");
      }
    }
  }

  Future<void> _savePosition() async {
    final song = currentSongNotifier.value;
    if (song != null) {
      try {
        await _lastPlayedService.saveLastPlayed(
          song.id,
          positionNotifier.value,
          playlistSongIds: _playlist.map((s) => s.id).toList(),
          currentIndex: _currentIndex,
        );
      } catch (e) {
        debugPrint('Failed to save last played position: $e');
      }
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

      currentSongNotifier.value = _playlist[_currentIndex];
      final restoredSong = currentSongNotifier.value;
      if (restoredSong != null) {
        _startReplayTracking(
          restoredSong,
          initialPosition: lastPlayed.position,
        );
      }

      if (restoredSong?.filePath != null) {
        try {
          positionNotifier.value = lastPlayed.position;
          durationNotifier.value =
              currentSongNotifier.value?.duration ?? Duration.zero;

          final isFav = await _favoritesService.isFavorite(restoredSong!.id);
          await _notificationService.showNotification(
            song: restoredSong,
            isPlaying: false,
            position: lastPlayed.position,
            isShuffle: isShuffleNotifier.value,
            isFavorite: isFav,
          );
          await _syncUac2PlaybackStatus(restoredSong, isPlaying: false);
        } catch (e) {
          debugPrint("Error restoring last played: $e");
        }
      }
    }
  }

  Future<void> pause() async {
    // Immediately update the playing state for responsive UI
    isPlayingNotifier.value = false;

    if (_usingRustBackend) {
      await _rustAudioService.pause();
    } else {
      await _justAudioPlayer.pause();
    }
    await _syncUac2PlaybackStatus(currentSongNotifier.value, isPlaying: false);
    await _savePosition();
    _updateNotificationState();
  }

  Future<void> resume() async {
    await initAudio();

    final song = currentSongNotifier.value;

    // Immediately update the playing state for responsive UI
    isPlayingNotifier.value = true;

    if (_usingRustBackend) {
      await _rustAudioService.resume();
      await _syncUac2PlaybackStatus(song, isPlaying: true);
      _updateNotificationState();
      return;
    }

    if (song?.filePath != null &&
        _justAudioPlayer.processingState == just_audio.ProcessingState.idle) {
      // Rebuild playlist if needed
      final sources = await _buildAudioSources();
      final resumeIndex = _currentIndex >= 0 ? _currentIndex : 0;
      await _runWithSuppressedSequenceStateUpdates(() async {
        await _justAudioPlayer.setAudioSources(
          sources,
          initialIndex: resumeIndex,
          preload: true,
        );
        await _justAudioPlayer.seek(positionNotifier.value, index: resumeIndex);
      });
    }
    await _justAudioPlayer.play();
    await _syncUac2PlaybackStatus(song, isPlaying: true);
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
    if (_usingRustBackend) {
      try {
        await _rustAudioService.seek(position);
        positionNotifier.value = position;
      } catch (e) {
        debugPrint('Rust fallback seek failed: $e');
      }
    } else {
      await _justAudioPlayer.seek(position);
    }
    _updateNotificationState();
  }

  Future<void> next() async {
    if (_playlist.isEmpty) return;

    debugPrint(
      'next(): currentIndex=$_currentIndex, playlistLength=${_playlist.length}, loopMode=${loopModeNotifier.value}',
    );

    if (_usingRustBackend) {
      if (_currentIndex < _playlist.length - 1) {
        _setCurrentIndex(_currentIndex + 1);
        await play(_playlist[_currentIndex]);
      } else if (loopModeNotifier.value == LoopMode.all) {
        _setCurrentIndex(0);
        await play(_playlist[_currentIndex]);
      } else {
        await pause();
        await seek(Duration.zero);
      }
      return;
    }

    if (_currentIndex < _playlist.length - 1) {
      final targetIndex = _currentIndex + 1;
      debugPrint('next(): Advancing to index $_currentIndex');
      await _justAudioPlayer.seekToNext();
      _syncCurrentSongFromIndex(targetIndex);
    } else if (loopModeNotifier.value == LoopMode.all) {
      debugPrint('next(): LoopMode.all, wrapping to index 0');
      await _justAudioPlayer.seek(Duration.zero, index: 0);
      if (!isPlayingNotifier.value) {
        await _justAudioPlayer.play();
      }
      _syncCurrentSongFromIndex(0);
    } else {
      debugPrint('next(): End of playlist, pausing');
      await pause();
      await seek(Duration.zero);
    }
  }

  Future<void> previous() async {
    if (_playlist.isEmpty) return;

    if (_usingRustBackend) {
      if (positionNotifier.value.inSeconds > 3) {
        await seek(Duration.zero);
      } else {
        if (_currentIndex > 0) {
          _setCurrentIndex(_currentIndex - 1);
          await play(_playlist[_currentIndex]);
        } else {
          await seek(Duration.zero);
        }
      }
      return;
    }

    if (positionNotifier.value.inSeconds > 3) {
      await seek(Duration.zero);
    } else {
      if (_currentIndex > 0) {
        final targetIndex = _currentIndex - 1;
        await _justAudioPlayer.seekToPrevious();
        _syncCurrentSongFromIndex(targetIndex);
      } else {
        await seek(Duration.zero);
      }
    }
  }

  /// Rebuild the current playlist with updated settings
  Future<void> _rebuildPlaylist() async {
    if (_usingRustBackend) return;
    if (_playlist.isEmpty || _currentIndex < 0) return;

    try {
      _isRebuildingPlaylist = true;
      final wasPlaying = isPlayingNotifier.value;
      final currentPosition = positionNotifier.value;

      final sources = await _buildAudioSources();

      await _runWithSuppressedSequenceStateUpdates(() async {
        await _justAudioPlayer.setAudioSources(
          sources,
          initialIndex: _currentIndex,
          preload: true,
        );

        await _justAudioPlayer.seek(currentPosition, index: _currentIndex);
        await _updateLoopMode();
      });

      if (wasPlaying) {
        await _justAudioPlayer.play();
      }
    } catch (e) {
      debugPrint('Error rebuilding playlist: $e');
    } finally {
      _isRebuildingPlaylist = false;
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

    if (enable) {
      basePlaylist.shuffle();
    } else {
      basePlaylist
        ..clear()
        ..addAll(_originalPlaylist);
      if (current != null &&
          !basePlaylist.any((song) => song.id == current.id)) {
        final insertionIndex = _currentIndex.clamp(0, basePlaylist.length);
        basePlaylist.insert(insertionIndex, current);
      }
    }

    _playlist
      ..clear()
      ..addAll(basePlaylist);
    _playlistQueueEntryIds
      ..clear()
      ..addAll(List<int?>.filled(basePlaylist.length, null));
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
    if (_usingRustBackend) {
      await _rustAudioService.setVolume(volume);
    } else {
      await _justAudioPlayer.setVolume(volume);
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

  Future<void> playFromQueueIndex(int index) async {
    if (index < 0 || index >= _queuedEntries.length) return;
    final entry = _queuedEntries.removeAt(index);
    final playlistIndex = _findPlaylistIndexForQueueEntry(entry.id);
    if (playlistIndex != -1) {
      _playlistQueueEntryIds[playlistIndex] = null;
      _notifyQueueChanged();
      if (_usingRustBackend) {
        _setCurrentIndex(playlistIndex);
        await play(_playlist[playlistIndex]);
        return;
      }
      _setCurrentIndex(playlistIndex);
      currentSongNotifier.value = _playlist[playlistIndex];
      _startReplayTracking(_playlist[playlistIndex]);
      positionNotifier.value = Duration.zero;
      await _justAudioPlayer.seek(Duration.zero, index: playlistIndex);
      if (!isPlayingNotifier.value) {
        await _justAudioPlayer.play();
      }
      _updateNotificationState();
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
      await _justAudioPlayer.setSpeed(clampedSpeed);
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

  void dispose() {
    _positionSaveTimer?.cancel();
    cancelSleepTimer();
    _notificationService.hideNotification();
    if (_usingRustBackend) {
      unawaited(_rustAudioService.stop());
    }

    _justAudioPlayer.dispose();

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
