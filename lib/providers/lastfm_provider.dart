import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:flick/services/lastfm/lastfm_auth_service.dart';
import 'package:flick/services/lastfm/lastfm_api_client.dart';
import 'package:flick/services/lastfm/lastfm_credentials.dart';
import 'package:flick/services/lastfm/lastfm_models.dart';
import 'package:flick/services/lastfm/lastfm_scrobble_queue.dart';
import 'package:flick/services/lastfm/lastfm_scrobble_service.dart';

part 'lastfm_provider.g.dart';

@Riverpod(keepAlive: true)
LastFmCredentials lastFmCredentials(Ref ref) {
  return LastFmCredentials();
}

@Riverpod(keepAlive: true)
LastFmApiClient lastFmApiClient(Ref ref) {
  final credentials = ref.watch(lastFmCredentialsProvider);
  return LastFmApiClient(credentials: credentials);
}

@Riverpod(keepAlive: true)
LastFmAuthService lastFmAuthService(Ref ref) {
  final credentials = ref.watch(lastFmCredentialsProvider);
  final client = ref.watch(lastFmApiClientProvider);
  return LastFmAuthService(client: client, credentials: credentials);
}

@Riverpod(keepAlive: true)
LastFmScrobbleService lastFmScrobbleService(Ref ref) {
  final auth = ref.watch(lastFmAuthServiceProvider);
  return LastFmScrobbleService(auth: auth);
}

@Riverpod(keepAlive: true)
LastFmScrobbleQueue lastFmScrobbleQueue(Ref ref) {
  final service = ref.watch(lastFmScrobbleServiceProvider);
  return LastFmScrobbleQueue(service: service);
}

/// Watches the current Last.fm session (null = not connected).
@riverpod
Future<LastFmSession?> lastFmSession(Ref ref) async {
  final auth = ref.watch(lastFmAuthServiceProvider);
  return auth.getSession();
}

/// Handles Last.fm scrobbling lifecycle hooks from playback events.
@Riverpod(keepAlive: true)
class LastFmScrobbleNotifier extends _$LastFmScrobbleNotifier {
  DateTime? _playbackStart;
  ScrobbleEntry? _currentEntry;
  bool _hasScrobbledCurrent = false;

  /// Monotonic counter to cancel stale now-playing calls during rapid
  /// track changes (e.g. gapless transitions).
  int _trackGeneration = 0;

  @override
  void build() {}

  Future<void> onTrackStarted({
    required String artist,
    required String track,
    String? album,
    String? albumArtist,
    int? durationSeconds,
  }) async {
    final gen = ++_trackGeneration;
    _playbackStart = DateTime.now();
    _hasScrobbledCurrent = false;

    // Validate metadata is not corrupted (mojibake/encoding issues)
    if (!_isValidMetadata(artist) || !_isValidMetadata(track)) {
      _currentEntry = null;
      return;
    }

    _currentEntry = ScrobbleEntry(
      artist: artist,
      track: track,
      album: album,
      albumArtist: albumArtist,
      timestamp: _playbackStart!.millisecondsSinceEpoch ~/ 1000,
      durationSeconds: durationSeconds,
    );

    // Skip now-playing if a newer onTrackStarted already fired
    if (gen != _trackGeneration) return;

    final scrobbler = ref.read(lastFmScrobbleServiceProvider);
    await scrobbler.updateNowPlaying(_currentEntry!);
  }

  /// Called while playback is in progress. Not used for scrobbling—we only
  /// scrobble on explicit track end/skip events to avoid API spam from
  /// repeated progress updates.
  Future<void> onPlaybackProgress({
    String? artist,
    String? track,
    String? album,
    String? albumArtist,
    required int listenedSeconds,
    int? trackDurationSeconds,
  }) async {
    // Scrobbling is triggered only on track-end/skip, not progress updates.
    // This prevents submitting the same track multiple times per second.
  }

  Future<void> onTrackEnded({
    String? artist,
    String? track,
    String? album,
    String? albumArtist,
    required int listenedSeconds,
    int? trackDurationSeconds,
  }) async {
    // Skip scrobbling if metadata is corrupted
    if ((artist != null && !_isValidMetadata(artist)) ||
        (track != null && !_isValidMetadata(track))) {
      _currentEntry = null;
      _playbackStart = null;
      return;
    }
    await _tryScrobble(
      fallbackArtist: artist,
      fallbackTrack: track,
      fallbackAlbum: album,
      fallbackAlbumArtist: albumArtist,
      listenedSeconds: listenedSeconds,
      trackDurationSeconds: trackDurationSeconds,
    );

    _currentEntry = null;
    _playbackStart = null;
  }

  Future<void> _tryScrobble({
    String? fallbackArtist,
    String? fallbackTrack,
    String? fallbackAlbum,
    String? fallbackAlbumArtist,
    required int listenedSeconds,
    int? trackDurationSeconds,
  }) async {
    if (_hasScrobbledCurrent) {
      return;
    }

    final start = _playbackStart;
    var entry = _currentEntry;

    // Prefer fresh fallback metadata (from track-end) over potentially stale _currentEntry.
    // This handles the case where player metadata is corrected between track-start and track-end.
    if (fallbackArtist != null && fallbackTrack != null) {
      final timestamp =
          DateTime.now()
              .subtract(Duration(seconds: listenedSeconds))
              .millisecondsSinceEpoch ~/
          1000;
      entry = ScrobbleEntry(
        artist: fallbackArtist,
        track: fallbackTrack,
        album: fallbackAlbum,
        albumArtist: fallbackAlbumArtist,
        timestamp: timestamp,
        durationSeconds: trackDurationSeconds,
      );
    } else if (entry == null || start == null) {
      return;
    }

    final scrobbler = ref.read(lastFmScrobbleServiceProvider);
    final queue = ref.read(lastFmScrobbleQueueProvider);

    final durationSeconds =
        (trackDurationSeconds != null && trackDurationSeconds > 0)
        ? trackDurationSeconds
        : entry.durationSeconds;
    if (durationSeconds == null || durationSeconds <= 0) {
      debugPrint('[LastFm] scrobble skipped: missing or zero duration');
      return;
    }

    final eligible = scrobbler.isEligibleToScrobble(
      trackDurationSeconds: durationSeconds,
      listenedSeconds: listenedSeconds,
    );

    if (!eligible) {
      return;
    }
    await queue.enqueue(entry);
    _hasScrobbledCurrent = true;
    try {
      await queue.flush();
    } catch (e) {
      // Offline or transient failure. Keep queued for later retry.
      debugPrint('[LastFm] flush failed: $e');
    }
  }

  /// Check if metadata looks valid or corrupted (mojibake pattern detection).
  /// Returns false for garbled text with suspicious UTF-8 sequences.
  bool _isValidMetadata(String text) {
    if (text.isEmpty) return false;

    // Check for mojibake patterns: high density of replacement characters
    // that indicate encoding corruption. Only flag U+FFFD and letterlike
    // symbols — avoid false-positives on legitimate non-Latin scripts
    // (Japanese, Korean, Greek, etc.).
    int suspiciousCharCount = 0;
    for (final char in text.runes) {
      if (char == 0xFFFD || // Replacement char (invalid UTF-8)
          (char >= 0x2100 && char <= 0x214F)) {
        // Letterlike symbols (suspicious)
        suspiciousCharCount++;
      }
    }

    // If more than 40% of characters are suspicious, likely mojibake
    final suspicionRatio = suspiciousCharCount / text.length;
    if (suspicionRatio > 0.4) {
      return false;
    }

    return true;
  }
}
