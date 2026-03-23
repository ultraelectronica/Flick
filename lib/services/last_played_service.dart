import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:flick/models/song.dart';
import 'package:flick/data/repositories/song_repository.dart';

/// Service for persisting and restoring the last played song.
class LastPlayedService {
  static const String _lastSongIdKey = 'last_played_song_id';
  static const String _lastPositionKey = 'last_played_position_ms';
  static const String _lastPlaylistSongIdsKey = 'last_played_playlist_song_ids';
  static const String _lastPlaylistIndexKey = 'last_played_playlist_index';

  final SongRepository _songRepository;

  LastPlayedService({SongRepository? songRepository})
    : _songRepository = songRepository ?? SongRepository();

  /// Save the currently playing song ID and position.
  ///
  /// Optionally stores the active playlist context so next/previous work
  /// correctly after app relaunch.
  Future<void> saveLastPlayed(
    String songId,
    Duration position, {
    List<String>? playlistSongIds,
    int? currentIndex,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastSongIdKey, songId);
    await prefs.setInt(_lastPositionKey, position.inMilliseconds);

    if (playlistSongIds != null && playlistSongIds.isNotEmpty) {
      await prefs.setString(
        _lastPlaylistSongIdsKey,
        jsonEncode(playlistSongIds),
      );
      if (currentIndex != null && currentIndex >= 0) {
        await prefs.setInt(_lastPlaylistIndexKey, currentIndex);
      }
    }
  }

  /// Get the last played song and position.
  /// Returns null if no song was previously played.
  Future<
    ({Song song, Duration position, List<Song>? playlist, int? playlistIndex})?
  >
  getLastPlayed() async {
    final prefs = await SharedPreferences.getInstance();
    final songId = prefs.getString(_lastSongIdKey);

    if (songId == null) return null;

    // Find the song in the database
    final allSongs = await _songRepository.getAllSongs();
    final song = allSongs.where((s) => s.id == songId).firstOrNull;

    if (song == null) return null;

    List<Song>? restoredPlaylist;
    int? restoredPlaylistIndex;
    final playlistSongIdsRaw = prefs.getString(_lastPlaylistSongIdsKey);
    if (playlistSongIdsRaw != null) {
      try {
        final dynamic decoded = jsonDecode(playlistSongIdsRaw);
        if (decoded is List) {
          final playlistSongIds = decoded.whereType<String>().toList();
          if (playlistSongIds.isNotEmpty) {
            final songsById = {for (final s in allSongs) s.id: s};
            final mapped = <Song>[];
            for (final id in playlistSongIds) {
              final found = songsById[id];
              if (found != null) {
                mapped.add(found);
              }
            }
            if (mapped.isNotEmpty) {
              restoredPlaylist = mapped;
              final storedIndex = prefs.getInt(_lastPlaylistIndexKey);
              if (storedIndex != null &&
                  storedIndex >= 0 &&
                  storedIndex < mapped.length) {
                restoredPlaylistIndex = storedIndex;
              } else {
                final songIndex = mapped.indexWhere((s) => s.id == song.id);
                restoredPlaylistIndex = songIndex >= 0 ? songIndex : 0;
              }
            }
          }
        }
      } catch (_) {
        // Ignore invalid or stale persisted playlist JSON.
      }
    }

    final positionMs = prefs.getInt(_lastPositionKey) ?? 0;
    return (
      song: song,
      position: Duration(milliseconds: positionMs),
      playlist: restoredPlaylist,
      playlistIndex: restoredPlaylistIndex,
    );
  }

  /// Clear the last played state.
  Future<void> clearLastPlayed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastSongIdKey);
    await prefs.remove(_lastPositionKey);
    await prefs.remove(_lastPlaylistSongIdsKey);
    await prefs.remove(_lastPlaylistIndexKey);
  }
}
