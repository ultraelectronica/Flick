import 'package:flutter/foundation.dart';

import 'package:flick/services/lastfm/lastfm_api_client.dart';
import 'package:flick/services/lastfm/lastfm_auth_service.dart';
import 'package:flick/services/lastfm/lastfm_models.dart';

/// Handles Now Playing updates and scrobble submissions to Last.fm.
class LastFmScrobbleService {
  LastFmScrobbleService({LastFmApiClient? client, LastFmAuthService? auth})
    : _client = client ?? LastFmApiClient(),
      _auth = auth ?? LastFmAuthService();

  final LastFmApiClient _client;
  final LastFmAuthService _auth;

  /// Returns true if the track meets Last.fm scrobble requirements.
  bool isEligibleToScrobble({
    required int trackDurationSeconds,
    required int listenedSeconds,
  }) {
    if (trackDurationSeconds < 30) {
      return false;
    }

    final percent = listenedSeconds / trackDurationSeconds * 100;
    return percent >= 50 || listenedSeconds >= 240;
  }

  /// Call at playback start to update Last.fm "Now Playing".
  Future<void> updateNowPlaying(ScrobbleEntry entry) async {
    final session = await _auth.getSession();
    if (session == null) {
      debugPrint('[LastFm] now-playing skipped: no session');
      return;
    }

    try {
      debugPrint(
        '[LastFm] now-playing send artist="${entry.artist}" track="${entry.track}"',
      );
      await _client.post({
        'method': 'track.updateNowPlaying',
        'sk': session.sessionKey,
        'artist': entry.artist,
        'track': entry.track,
        if (entry.album != null) 'album': entry.album!,
        if (entry.albumArtist != null) 'albumArtist': entry.albumArtist!,
        if (entry.durationSeconds != null)
          'duration': entry.durationSeconds.toString(),
      });
      debugPrint('[LastFm] now-playing success');
    } catch (_) {
      // Now Playing is non-critical; failures are intentionally ignored.
      debugPrint('[LastFm] now-playing failed');
    }
  }

  Future<void> scrobble(ScrobbleEntry entry) async {
    await scrobbleBatch([entry]);
  }

  /// Batch scrobble up to 50 tracks per API call.
  Future<void> scrobbleBatch(List<ScrobbleEntry> entries) async {
    if (entries.isEmpty) {
      debugPrint('[LastFm] scrobble skipped: empty batch');
      return;
    }

    final session = await _auth.getSession();
    if (session == null) {
      debugPrint('[LastFm] scrobble skipped: no session');
      return;
    }

    const maxBatch = 50;
    for (var i = 0; i < entries.length; i += maxBatch) {
      final batch = entries.skip(i).take(maxBatch).toList();
      debugPrint('[LastFm] scrobble send batchSize=${batch.length}');
      final params = <String, String>{
        'method': 'track.scrobble',
        'sk': session.sessionKey,
      };

      for (var j = 0; j < batch.length; j++) {
        final entry = batch[j];
        final indexSuffix = batch.length > 1 ? '[$j]' : '';

        params['artist$indexSuffix'] = entry.artist;
        params['track$indexSuffix'] = entry.track;
        params['timestamp$indexSuffix'] = entry.timestamp.toString();

        if (entry.album != null) {
          params['album$indexSuffix'] = entry.album!;
        }
        if (entry.albumArtist != null) {
          params['albumArtist$indexSuffix'] = entry.albumArtist!;
        }
        if (entry.durationSeconds != null) {
          params['duration$indexSuffix'] = entry.durationSeconds.toString();
        }
      }

      await _client.post(params);
      debugPrint('[LastFm] scrobble batch success');
    }
  }
}
