import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:flick/models/playlist.dart';

class PlaylistService {
  static const String _playlistsKey = 'playlists';

  List<Playlist> _playlists = [];
  bool _isLoaded = false;

  Future<void> _ensureLoaded() async {
    if (_isLoaded) return;

    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_playlistsKey);

    if (jsonString != null) {
      final List<dynamic> jsonList = json.decode(jsonString);
      _playlists = jsonList
          .map((item) => Playlist.fromJson(item as Map<String, dynamic>))
          .toList();
    }

    _isLoaded = true;
  }

  Future<List<Playlist>> getPlaylists() async {
    await _ensureLoaded();
    return List.from(_playlists);
  }

  Future<Playlist?> getPlaylist(String id) async {
    await _ensureLoaded();
    try {
      return _playlists.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }

  Future<Playlist> createPlaylist(String name) async {
    await _ensureLoaded();

    final playlist = Playlist(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      createdAt: DateTime.now(),
    );

    _playlists.add(playlist);
    await _savePlaylists();

    return playlist;
  }

  Future<Playlist?> updatePlaylist(Playlist playlist) async {
    await _ensureLoaded();

    final index = _playlists.indexWhere((p) => p.id == playlist.id);
    if (index == -1) return null;

    final updated = playlist.copyWith(updatedAt: DateTime.now());
    _playlists[index] = updated;
    await _savePlaylists();

    return updated;
  }

  Future<bool> deletePlaylist(String id) async {
    await _ensureLoaded();

    final initialLength = _playlists.length;
    _playlists.removeWhere((p) => p.id == id);

    if (_playlists.length < initialLength) {
      await _savePlaylists();
      return true;
    }

    return false;
  }

  Future<bool> addSongToPlaylist(String playlistId, String songId) async {
    await _ensureLoaded();

    final index = _playlists.indexWhere((p) => p.id == playlistId);
    if (index == -1) return false;

    final playlist = _playlists[index];
    if (playlist.songIds.contains(songId)) return true;

    final updated = playlist.copyWith(
      songIds: [...playlist.songIds, songId],
      updatedAt: DateTime.now(),
    );

    _playlists[index] = updated;
    await _savePlaylists();

    return true;
  }

  Future<bool> removeSongFromPlaylist(String playlistId, String songId) async {
    await _ensureLoaded();

    final index = _playlists.indexWhere((p) => p.id == playlistId);
    if (index == -1) return false;

    final playlist = _playlists[index];
    final updated = playlist.copyWith(
      songIds: playlist.songIds.where((id) => id != songId).toList(),
      updatedAt: DateTime.now(),
    );

    _playlists[index] = updated;
    await _savePlaylists();

    return true;
  }

  Future<void> _savePlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = json.encode(_playlists.map((p) => p.toJson()).toList());
    await prefs.setString(_playlistsKey, jsonString);
  }

  Future<void> clearAll() async {
    _playlists.clear();
    await _savePlaylists();
  }
}
