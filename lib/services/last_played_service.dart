import 'package:shared_preferences/shared_preferences.dart';
import 'package:flick/models/song.dart';
import 'package:flick/data/repositories/song_repository.dart';

/// Service for persisting and restoring the last played song.
class LastPlayedService {
  static const String _lastSongIdKey = 'last_played_song_id';
  static const String _lastPositionKey = 'last_played_position_ms';

  final SongRepository _songRepository;

  LastPlayedService({SongRepository? songRepository})
    : _songRepository = songRepository ?? SongRepository();

  /// Save the currently playing song ID and position.
  Future<void> saveLastPlayed(String songId, Duration position) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastSongIdKey, songId);
    await prefs.setInt(_lastPositionKey, position.inMilliseconds);
  }

  /// Get the last played song and position.
  /// Returns null if no song was previously played.
  Future<({Song song, Duration position})?> getLastPlayed() async {
    final prefs = await SharedPreferences.getInstance();
    final songId = prefs.getString(_lastSongIdKey);

    if (songId == null) return null;

    // Find the song in the database
    final allSongs = await _songRepository.getAllSongs();
    final song = allSongs.where((s) => s.id == songId).firstOrNull;

    if (song == null) return null;

    final positionMs = prefs.getInt(_lastPositionKey) ?? 0;
    return (song: song, position: Duration(milliseconds: positionMs));
  }

  /// Clear the last played state.
  Future<void> clearLastPlayed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastSongIdKey);
    await prefs.remove(_lastPositionKey);
  }
}
