import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/song.dart';
import '../data/repositories/song_repository.dart';

/// Provider for the SongRepository.
final songRepositoryProvider = Provider<SongRepository>((ref) {
  return SongRepository();
});

/// Sort options for the song list.
enum SongSortOption { title, artist, dateAdded }

/// State for the songs list with sorting.
class SongsState {
  final List<Song> songs;
  final SongSortOption sortOption;

  const SongsState({
    this.songs = const [],
    this.sortOption = SongSortOption.title,
  });

  SongsState copyWith({List<Song>? songs, SongSortOption? sortOption}) {
    return SongsState(
      songs: songs ?? this.songs,
      sortOption: sortOption ?? this.sortOption,
    );
  }

  /// Get sorted songs based on current sort option.
  List<Song> get sortedSongs {
    final sorted = List<Song>.from(songs);
    switch (sortOption) {
      case SongSortOption.title:
        sorted.sort((a, b) => a.title.compareTo(b.title));
      case SongSortOption.artist:
        sorted.sort((a, b) => a.artist.compareTo(b.artist));
      case SongSortOption.dateAdded:
        sorted.sort((a, b) {
          final dateA = a.dateAdded ?? DateTime.fromMillisecondsSinceEpoch(0);
          final dateB = b.dateAdded ?? DateTime.fromMillisecondsSinceEpoch(0);
          return dateB.compareTo(dateA); // Newest first
        });
    }
    return sorted;
  }
}

/// AsyncNotifier for managing the songs list.
/// Uses autoDispose to clean up when not being watched.
class SongsNotifier extends AsyncNotifier<SongsState> {
  StreamSubscription<void>? _watchSubscription;
  SongSortOption _sortOption = SongSortOption.title;

  @override
  Future<SongsState> build() async {
    final repository = ref.watch(songRepositoryProvider);

    // Watch for database changes and refresh
    _watchSubscription?.cancel();
    _watchSubscription = repository.watchSongs().listen((_) {
      // Invalidate self to trigger rebuild
      ref.invalidateSelf();
    });

    // Cleanup subscription on dispose
    ref.onDispose(() {
      _watchSubscription?.cancel();
    });

    final songs = await repository.getAllSongs();
    return SongsState(songs: songs, sortOption: _sortOption);
  }

  /// Change the sort option.
  void setSortOption(SongSortOption option) {
    _sortOption = option;
    final currentState = state.value;
    if (currentState != null) {
      state = AsyncData(currentState.copyWith(sortOption: option));
    }
  }

  /// Force refresh the songs list.
  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() => build());
  }
}

/// Main songs provider with async data loading.
final songsProvider =
    AsyncNotifierProvider.autoDispose<SongsNotifier, SongsState>(
      SongsNotifier.new,
    );

/// Convenience provider for just the sorted song list.
final sortedSongsProvider = Provider.autoDispose<AsyncValue<List<Song>>>((ref) {
  return ref.watch(songsProvider).whenData((state) => state.sortedSongs);
});

/// Song count provider.
final songCountProvider = Provider.autoDispose<int>((ref) {
  return ref.watch(songsProvider).value?.songs.length ?? 0;
});

// ============================================================================
// Album and Artist grouping providers
// ============================================================================

/// Songs grouped by album.
final songsByAlbumProvider =
    FutureProvider.autoDispose<Map<String, List<Song>>>((ref) async {
      final repository = ref.watch(songRepositoryProvider);
      return repository.getSongsByAlbum();
    });

/// Songs grouped by artist.
final songsByArtistProvider =
    FutureProvider.autoDispose<Map<String, List<Song>>>((ref) async {
      final repository = ref.watch(songRepositoryProvider);
      return repository.getSongsByArtist();
    });

// ============================================================================
// Search provider
// ============================================================================

/// Notifier for search query state.
class SearchQueryNotifier extends Notifier<String> {
  @override
  String build() => '';

  void setQuery(String query) {
    state = query;
  }

  void clear() {
    state = '';
  }
}

/// Search query state provider.
final searchQueryProvider =
    NotifierProvider.autoDispose<SearchQueryNotifier, String>(
      SearchQueryNotifier.new,
    );

/// Filtered songs based on search query.
final searchResultsProvider = FutureProvider.autoDispose<List<Song>>((
  ref,
) async {
  final query = ref.watch(searchQueryProvider);
  if (query.isEmpty) return [];

  final repository = ref.watch(songRepositoryProvider);
  return repository.searchSongs(query);
});
