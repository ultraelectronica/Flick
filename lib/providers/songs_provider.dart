import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/song.dart';
import '../data/repositories/song_repository.dart';

/// Provider for the SongRepository.
final songRepositoryProvider = Provider<SongRepository>((ref) {
  return SongRepository();
});

/// Sort options for the song list.
enum SongSortOption { title, artist, dateAdded, fileType }

/// Filter options for file types.
enum SongFileTypeFilter { all, flac, mp3, wav, aac, ogg, alac }

extension SongFileTypeFilterExtension on SongFileTypeFilter {
  String get displayName {
    switch (this) {
      case SongFileTypeFilter.all:
        return 'All Formats';
      case SongFileTypeFilter.flac:
        return 'FLAC';
      case SongFileTypeFilter.mp3:
        return 'MP3';
      case SongFileTypeFilter.wav:
        return 'WAV';
      case SongFileTypeFilter.aac:
        return 'AAC';
      case SongFileTypeFilter.ogg:
        return 'OGG';
      case SongFileTypeFilter.alac:
        return 'ALAC';
    }
  }

  bool matches(String fileType) {
    if (this == SongFileTypeFilter.all) return true;
    return fileType.toUpperCase() == displayName;
  }
}

/// State for the songs list with sorting.
class SongsState {
  final List<Song> songs;
  final SongSortOption sortOption;
  final SongFileTypeFilter fileTypeFilter;

  const SongsState({
    this.songs = const [],
    this.sortOption = SongSortOption.title,
    this.fileTypeFilter = SongFileTypeFilter.all,
  });

  SongsState copyWith({
    List<Song>? songs,
    SongSortOption? sortOption,
    SongFileTypeFilter? fileTypeFilter,
  }) {
    return SongsState(
      songs: songs ?? this.songs,
      sortOption: sortOption ?? this.sortOption,
      fileTypeFilter: fileTypeFilter ?? this.fileTypeFilter,
    );
  }

  /// Get sorted and filtered songs based on current options.
  List<Song> get sortedSongs {
    var result = List<Song>.from(songs);

    if (fileTypeFilter != SongFileTypeFilter.all) {
      result = result
          .where((song) => fileTypeFilter.matches(song.fileType))
          .toList();
    }

    switch (sortOption) {
      case SongSortOption.title:
        result.sort((a, b) => a.title.compareTo(b.title));
      case SongSortOption.artist:
        result.sort((a, b) => a.artist.compareTo(b.artist));
      case SongSortOption.dateAdded:
        result.sort((a, b) {
          final dateA = a.dateAdded ?? DateTime.fromMillisecondsSinceEpoch(0);
          final dateB = b.dateAdded ?? DateTime.fromMillisecondsSinceEpoch(0);
          return dateB.compareTo(dateA);
        });
      case SongSortOption.fileType:
        result.sort((a, b) => a.fileType.compareTo(b.fileType));
    }
    return result;
  }
}

/// AsyncNotifier for managing the songs list.
/// Uses autoDispose to clean up when not being watched.
class SongsNotifier extends AsyncNotifier<SongsState> {
  StreamSubscription<void>? _watchSubscription;
  SongSortOption _sortOption = SongSortOption.title;
  SongFileTypeFilter _fileTypeFilter = SongFileTypeFilter.all;

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
    return SongsState(
      songs: songs,
      sortOption: _sortOption,
      fileTypeFilter: _fileTypeFilter,
    );
  }

  /// Change the sort option.
  void setSortOption(SongSortOption option) {
    _sortOption = option;
    final currentState = state.value;
    if (currentState != null) {
      state = AsyncData(currentState.copyWith(sortOption: option));
    }
  }

  /// Change the file type filter.
  void setFileTypeFilter(SongFileTypeFilter filter) {
    _fileTypeFilter = filter;
    final currentState = state.value;
    if (currentState != null) {
      state = AsyncData(currentState.copyWith(fileTypeFilter: filter));
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
