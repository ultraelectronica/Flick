import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/models/playlist.dart';
import 'package:flick/services/playlist_service.dart';

final playlistServiceProvider = Provider<PlaylistService>((ref) {
  return PlaylistService();
});

class PlaylistsState {
  final List<Playlist> playlists;
  final bool isLoading;
  final String? error;

  const PlaylistsState({
    this.playlists = const [],
    this.isLoading = true,
    this.error,
  });

  PlaylistsState copyWith({
    List<Playlist>? playlists,
    bool? isLoading,
    String? error,
  }) {
    return PlaylistsState(
      playlists: playlists ?? this.playlists,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }

  Playlist? getPlaylist(String id) {
    try {
      return playlists.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }

  int get count => playlists.length;
}

class PlaylistsNotifier extends AsyncNotifier<PlaylistsState> {
  @override
  Future<PlaylistsState> build() async {
    final service = ref.watch(playlistServiceProvider);
    final playlists = await service.getPlaylists();

    return PlaylistsState(playlists: playlists, isLoading: false);
  }

  Future<Playlist?> createPlaylist(String name) async {
    if (name.trim().isEmpty) return null;

    final service = ref.read(playlistServiceProvider);
    final playlist = await service.createPlaylist(name.trim());
    ref.invalidateSelf();

    return playlist;
  }

  Future<bool> deletePlaylist(String id) async {
    final service = ref.read(playlistServiceProvider);
    final success = await service.deletePlaylist(id);

    if (success) {
      ref.invalidateSelf();
    }

    return success;
  }

  Future<bool> renamePlaylist(String id, String newName) async {
    if (newName.trim().isEmpty) return false;

    final service = ref.read(playlistServiceProvider);
    final playlist = await service.getPlaylist(id);

    if (playlist == null) return false;

    final updated = await service.updatePlaylist(
      playlist.copyWith(name: newName.trim()),
    );

    if (updated != null) {
      ref.invalidateSelf();
      return true;
    }

    return false;
  }

  Future<bool> addSongToPlaylist(String playlistId, String songId) async {
    final service = ref.read(playlistServiceProvider);
    final success = await service.addSongToPlaylist(playlistId, songId);

    if (success) {
      ref.invalidateSelf();
    }

    return success;
  }

  Future<bool> removeSongFromPlaylist(String playlistId, String songId) async {
    final service = ref.read(playlistServiceProvider);
    final success = await service.removeSongFromPlaylist(playlistId, songId);

    if (success) {
      ref.invalidateSelf();
    }

    return success;
  }
}

final playlistsProvider =
    AsyncNotifierProvider.autoDispose<PlaylistsNotifier, PlaylistsState>(
      PlaylistsNotifier.new,
    );

final playlistProvider = Provider.autoDispose.family<Playlist?, String>((
  ref,
  id,
) {
  return ref.watch(playlistsProvider).value?.getPlaylist(id);
});

final playlistsCountProvider = Provider.autoDispose<int>((ref) {
  return ref.watch(playlistsProvider).value?.count ?? 0;
});
