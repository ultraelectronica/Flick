import 'package:shared_preferences/shared_preferences.dart';
import 'package:flick/models/song.dart';
import 'package:flick/data/repositories/song_repository.dart';

/// Service for managing favorite songs.
/// Stores favorite song IDs in SharedPreferences for persistence.
class FavoritesService {
  static const String _favoritesKey = 'favorite_song_ids';

  final SongRepository _songRepository;

  // Cached set of favorite IDs for quick lookup
  Set<String> _favoriteIds = {};
  bool _isLoaded = false;

  FavoritesService({SongRepository? songRepository})
    : _songRepository = songRepository ?? SongRepository();

  /// Load favorites from SharedPreferences.
  Future<void> _ensureLoaded() async {
    if (_isLoaded) return;

    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_favoritesKey) ?? [];
    _favoriteIds = ids.toSet();
    _isLoaded = true;
  }

  /// Get all favorite songs.
  Future<List<Song>> getFavorites() async {
    await _ensureLoaded();

    if (_favoriteIds.isEmpty) return [];

    // Get all songs and filter by favorite IDs
    final allSongs = await _songRepository.getAllSongs();
    return allSongs.where((song) => _favoriteIds.contains(song.id)).toList();
  }

  /// Check if a song is a favorite.
  Future<bool> isFavorite(String songId) async {
    await _ensureLoaded();
    return _favoriteIds.contains(songId);
  }

  /// Add a song to favorites.
  Future<void> addFavorite(String songId) async {
    await _ensureLoaded();

    _favoriteIds.add(songId);
    await _saveFavorites();
  }

  /// Remove a song from favorites.
  Future<void> removeFavorite(String songId) async {
    await _ensureLoaded();

    _favoriteIds.remove(songId);
    await _saveFavorites();
  }

  /// Toggle favorite status for a song.
  /// Returns true if the song is now a favorite, false otherwise.
  Future<bool> toggleFavorite(String songId) async {
    await _ensureLoaded();

    if (_favoriteIds.contains(songId)) {
      _favoriteIds.remove(songId);
      await _saveFavorites();
      return false;
    } else {
      _favoriteIds.add(songId);
      await _saveFavorites();
      return true;
    }
  }

  /// Get the count of favorite songs.
  Future<int> getFavoritesCount() async {
    await _ensureLoaded();
    return _favoriteIds.length;
  }

  /// Save favorites to SharedPreferences.
  Future<void> _saveFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_favoritesKey, _favoriteIds.toList());
  }

  /// Clear all favorites.
  Future<void> clearFavorites() async {
    _favoriteIds.clear();
    await _saveFavorites();
  }
}
