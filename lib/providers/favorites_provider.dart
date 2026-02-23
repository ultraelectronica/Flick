import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/song.dart';
import '../services/favorites_service.dart';

/// Provider for the FavoritesService.
final favoritesServiceProvider = Provider<FavoritesService>((ref) {
  return FavoritesService();
});

/// State for favorites management.
class FavoritesState {
  final Set<String> favoriteIds;
  final List<Song> favoriteSongs;
  final bool isLoading;

  const FavoritesState({
    this.favoriteIds = const {},
    this.favoriteSongs = const [],
    this.isLoading = true,
  });

  FavoritesState copyWith({
    Set<String>? favoriteIds,
    List<Song>? favoriteSongs,
    bool? isLoading,
  }) {
    return FavoritesState(
      favoriteIds: favoriteIds ?? this.favoriteIds,
      favoriteSongs: favoriteSongs ?? this.favoriteSongs,
      isLoading: isLoading ?? this.isLoading,
    );
  }

  /// Check if a song is a favorite.
  bool isFavorite(String songId) => favoriteIds.contains(songId);

  /// Number of favorites.
  int get count => favoriteIds.length;
}

/// AsyncNotifier for favorites with autoDispose.
class FavoritesNotifier extends AsyncNotifier<FavoritesState> {
  @override
  Future<FavoritesState> build() async {
    final service = ref.watch(favoritesServiceProvider);

    final songs = await service.getFavorites();
    final ids = songs.map((s) => s.id).toSet();

    return FavoritesState(
      favoriteIds: ids,
      favoriteSongs: songs,
      isLoading: false,
    );
  }

  /// Toggle favorite status for a song.
  Future<bool> toggleFavorite(String songId) async {
    final service = ref.read(favoritesServiceProvider);
    final isFavorite = await service.toggleFavorite(songId);

    // Refresh state
    ref.invalidateSelf();

    return isFavorite;
  }

  /// Add a song to favorites.
  Future<void> addFavorite(String songId) async {
    final service = ref.read(favoritesServiceProvider);
    await service.addFavorite(songId);
    ref.invalidateSelf();
  }

  /// Remove a song from favorites.
  Future<void> removeFavorite(String songId) async {
    final service = ref.read(favoritesServiceProvider);
    await service.removeFavorite(songId);
    ref.invalidateSelf();
  }

  /// Clear all favorites.
  Future<void> clearFavorites() async {
    final service = ref.read(favoritesServiceProvider);
    await service.clearFavorites();
    ref.invalidateSelf();
  }
}

/// Main favorites provider.
final favoritesProvider =
    AsyncNotifierProvider.autoDispose<FavoritesNotifier, FavoritesState>(
      FavoritesNotifier.new,
    );

/// Convenience provider to check if a specific song is a favorite.
/// Usage: ref.watch(isSongFavoriteProvider(songId))
final isSongFavoriteProvider = Provider.autoDispose.family<bool, String>((
  ref,
  songId,
) {
  final favorites = ref.watch(favoritesProvider).value;
  return favorites?.isFavorite(songId) ?? false;
});

/// Favorites count provider.
final favoritesCountProvider = Provider.autoDispose<int>((ref) {
  return ref.watch(favoritesProvider).value?.count ?? 0;
});
