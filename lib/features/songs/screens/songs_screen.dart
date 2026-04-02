import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/core/utils/navigation_helper.dart';
import 'package:flick/models/song.dart';
import 'package:flick/models/song_view_mode.dart';
import 'package:flick/features/songs/widgets/orbit_scroll.dart';
import 'package:flick/features/songs/widgets/song_fast_index_overlay.dart';
import 'package:flick/features/songs/widgets/song_actions_bottom_sheet.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/widgets/common/glass_search_bar.dart';
import 'package:flick/widgets/common/display_mode_wrapper.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Main songs screen with orbital scrolling.
class SongsScreen extends ConsumerStatefulWidget {
  /// Callback when navigation to a different tab is requested from full player
  final ValueChanged<int>? onNavigationRequested;

  const SongsScreen({super.key, this.onNavigationRequested});

  @override
  ConsumerState<SongsScreen> createState() => _SongsScreenState();
}

class _SongsScreenState extends ConsumerState<SongsScreen> {
  static const double _listItemExtent = 80;

  int _selectedIndex = 0;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _listScrollController = ScrollController();
  final OrbitScrollController _orbitScrollController = OrbitScrollController();
  String _searchQuery = '';
  List<Song> _cachedSongs = [];
  String _selectedFastToken = 'A';
  late final ProviderSubscription<Song?> _currentSongSubscription;
  bool _alignedCurrentSongAfterLoad = false;

  @override
  void initState() {
    super.initState();
    _currentSongSubscription = ref.listenManual<Song?>(currentSongProvider, (
      previous,
      next,
    ) {
      _syncInterfaceToCurrentSong(next);
    });
  }

  @override
  void dispose() {
    _currentSongSubscription.close();
    _listScrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final songsAsync = ref.watch(songsProvider);
    final viewMode = ref.watch(songsViewModeProvider);
    final navBarAlwaysVisible = ref.watch(navBarAlwaysVisibleProvider);

    final shouldReserveBottomSpace =
        viewMode != SongViewMode.list || navBarAlwaysVisible;

    return DisplayModeWrapper(
      child: Stack(
        children: [
          // Background ambient effects
          _buildAmbientBackground(),

          // Main content
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                // Header with sort option
                _buildHeader(songsAsync),

                // Search Bar
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppConstants.spacingLg,
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          AppColors.surfaceLight.withValues(alpha: 0.75),
                          AppColors.surface.withValues(alpha: 0.85),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(
                        AppConstants.radiusXl,
                      ),
                      border: Border.all(
                        color: AppColors.glassBorder,
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 16,
                          spreadRadius: 1,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: GlassSearchBar(
                      controller: _searchController,
                      hintText: 'Search songs, artists...',
                      showBackground: false,
                      onChanged: (value) {
                        setState(() {
                          _searchQuery = value.toLowerCase();
                          _selectedIndex = 0;
                        });
                      },
                    ),
                  ),
                ),
                const SizedBox(height: AppConstants.spacingMd),

                // Content based on async state
                Expanded(
                  child: songsAsync.when(
                    loading: () => _buildLoadingState(),
                    error: (error, stack) => _buildErrorState(error),
                    data: (songsState) {
                      final allSongs = songsState.sortedSongs;
                      var songs = allSongs;
                      _cachedSongs = allSongs;

                      if (_searchQuery.isNotEmpty) {
                        songs = songs.where((song) {
                          return song.title.toLowerCase().contains(
                                _searchQuery,
                              ) ||
                              song.artist.toLowerCase().contains(_searchQuery);
                        }).toList();
                      }

                      if (songs.isEmpty && _searchQuery.isEmpty) {
                        return _buildEmptyState();
                      }

                      if (songs.isEmpty && _searchQuery.isNotEmpty) {
                        return _buildNoSearchResultsState();
                      }

                      _alignCurrentSongAfterSongsLoad(songs);

                      // Ensure selected index is valid
                      if (_selectedIndex >= songs.length) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) {
                            setState(() => _selectedIndex = 0);
                          }
                        });
                      }

                      _syncSelectedTokenForIndex(songs, _selectedIndex);

                      final tokenToIndexMap = _buildFastIndexMap(songs);

                      return _buildSongsView(
                        songs,
                        viewMode,
                        tokenToIndexMap,
                        shouldReserveBottomSpace,
                      );
                    },
                  ),
                ),

                // Reserve space only when needed for orbit view.
                // List view handles its own bottom padding.
                SizedBox(
                  height:
                      shouldReserveBottomSpace && viewMode != SongViewMode.list
                      ? AppConstants.navBarHeight + 90
                      : 0,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSongsView(
    List<Song> songs,
    SongViewMode viewMode,
    Map<String, int> tokenToIndexMap,
    bool shouldReserveBottomSpace,
  ) {
    final content = viewMode == SongViewMode.list
        ? _buildListView(songs)
        : _buildOrbitView(songs);

    if (tokenToIndexMap.isEmpty) {
      return content;
    }

    final songsAsync = ref.read(songsProvider);
    final sortOption =
        songsAsync.value?.sortOption ?? SongSortOption.albumArtist;

    // Get appropriate tokens based on sort option
    List<String> tokens = _getFastIndexTokens(sortOption);

    // For date sorting, generate tokens from actual years in the data
    if (sortOption == SongSortOption.dateAdded) {
      final years = tokenToIndexMap.keys.toList()
        ..sort((a, b) => b.compareTo(a));
      tokens = years;
    }

    // If tokens list is empty or we need to use actual data, use the keys from the map
    if (tokens.isEmpty || sortOption == SongSortOption.fileType) {
      tokens = tokenToIndexMap.keys.toList()..sort();
    }

    final railTopInset = AppConstants.spacingSm;
    final railBottomInset = shouldReserveBottomSpace
        ? AppConstants.spacingSm
        : AppConstants.navBarHeight + 90 + AppConstants.spacingSm;

    return Stack(
      children: [
        content,
        Positioned(
          right: AppConstants.spacingSm,
          top: railTopInset,
          bottom: railBottomInset,
          child: SongFastIndexOverlay(
            tokenToIndex: tokenToIndexMap,
            selectedToken: _selectedFastToken,
            tokens: tokens,
            onSelect: (token, animate) {
              _onFastIndexSelected(
                songs: songs,
                tokenToIndexMap: tokenToIndexMap,
                token: token,
                animate: animate,
                viewMode: viewMode,
                tokens: tokens,
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildOrbitView(List<Song> songs) {
    return GestureDetector(
      onLongPress: () {
        if (songs.isNotEmpty && _selectedIndex < songs.length) {
          SongActionsBottomSheet.show(context, songs[_selectedIndex]);
        }
      },
      child: OrbitScroll(
        controller: _orbitScrollController,
        songs: songs,
        selectedIndex: _selectedIndex.clamp(0, songs.length - 1).toInt(),
        onSelectedIndexChanged: (index) {
          if (!mounted) return;
          setState(() {
            _selectedIndex = index;
          });
          _syncSelectedTokenForIndex(songs, index);
        },
        onSongSelected: (index) async {
          await _playSongAndOpenPlayer(songs: songs, index: index);
        },
        onSongSwipedLeft: (index) async {
          await _queueSong(songs[index]);
        },
        onSongSwipedRight: (index) async {
          await _favoriteSong(songs[index]);
        },
      ),
    );
  }

  Widget _buildListView(List<Song> songs) {
    return ListView.builder(
      controller: _listScrollController,
      itemExtent: _listItemExtent,
      padding: const EdgeInsets.fromLTRB(
        AppConstants.spacingLg,
        0,
        AppConstants.spacingXl + 30,
        AppConstants.navBarHeight + 120,
      ),
      itemCount: songs.length,
      itemBuilder: (context, index) {
        final song = songs[index];
        final isSelected = index == _selectedIndex;

        return Padding(
          padding: const EdgeInsets.only(bottom: AppConstants.spacingSm),
          child: _QueueSwipeListItem(
            onQueued: () async {
              await _queueSong(song);
            },
            onFavorited: () async {
              await _favoriteSong(song);
            },
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(AppConstants.radiusLg),
                onTap: () async {
                  setState(() {
                    _selectedIndex = index;
                  });
                  _syncSelectedTokenForIndex(songs, index);
                  await _playSongAndOpenPlayer(songs: songs, index: index);
                },
                onLongPress: () {
                  SongActionsBottomSheet.show(context, song);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppConstants.spacingMd,
                    vertical: AppConstants.spacingSm,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppConstants.radiusLg),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: isSelected
                          ? [
                              AppColors.surfaceLight.withValues(alpha: 0.9),
                              AppColors.surface.withValues(alpha: 0.95),
                            ]
                          : [
                              AppColors.surfaceLight.withValues(alpha: 0.65),
                              AppColors.surface.withValues(alpha: 0.78),
                            ],
                    ),
                    border: Border.all(
                      color: isSelected
                          ? AppColors.accent.withValues(alpha: 0.45)
                          : AppColors.glassBorder,
                    ),
                  ),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(
                          AppConstants.radiusMd,
                        ),
                        child: SizedBox(
                          width: 46,
                          height: 46,
                          child: CachedImageWidget(
                            imagePath: song.albumArt,
                            audioSourcePath: song.filePath,
                            fit: BoxFit.cover,
                            useThumbnail: true,
                            thumbnailWidth: 92,
                            thumbnailHeight: 92,
                            placeholder: const ColoredBox(
                              color: AppColors.surface,
                              child: Icon(
                                LucideIcons.music,
                                color: AppColors.textTertiary,
                                size: 18,
                              ),
                            ),
                            errorWidget: const ColoredBox(
                              color: AppColors.surface,
                              child: Icon(
                                LucideIcons.music,
                                color: AppColors.textTertiary,
                                size: 18,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: AppConstants.spacingMd),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              song.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyLarge
                                  ?.copyWith(
                                    color: context.adaptiveTextPrimary,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${song.artist} • ${song.fileType.toUpperCase()}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: context.adaptiveTextSecondary,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: AppConstants.spacingSm),
                      Text(
                        song.formattedDuration,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: context.adaptiveTextTertiary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Map<String, int> _buildFastIndexMap(List<Song> songs) {
    final songsAsync = ref.read(songsProvider);
    final sortOption =
        songsAsync.value?.sortOption ?? SongSortOption.albumArtist;

    final map = <String, int>{};
    for (var i = 0; i < songs.length; i++) {
      final token = _tokenForSong(songs[i], sortOption);
      map.putIfAbsent(token, () => i);
    }
    return map;
  }

  String _tokenForSong(Song song, SongSortOption sortOption) {
    String text;

    switch (sortOption) {
      case SongSortOption.albumArtist:
        text = song.albumArtist ?? song.artist;
      case SongSortOption.artist:
        text = song.artist;
      case SongSortOption.title:
        text = song.title;
      case SongSortOption.dateAdded:
        // For date sorting, group by year
        final year = song.dateAdded?.year;
        if (year == null) return '#';
        return year.toString();
      case SongSortOption.fileType:
        // For file type sorting, use the file type itself
        return song.fileType.toUpperCase();
    }

    return _extractToken(text);
  }

  String _extractToken(String text) {
    final normalized = text.trim();
    if (normalized.isEmpty) return '#';

    final code = normalized.codeUnitAt(0);
    if (_isAsciiUpper(code)) {
      return String.fromCharCode(code);
    }

    if (_isDigit(code)) {
      return '0-9';
    }

    final upperCode = code >= 97 && code <= 122 ? code - 32 : code;
    if (_isAsciiUpper(upperCode)) {
      return String.fromCharCode(upperCode);
    }

    return '#';
  }

  bool _isAsciiUpper(int codeUnit) => codeUnit >= 65 && codeUnit <= 90;
  bool _isDigit(int codeUnit) => codeUnit >= 48 && codeUnit <= 57;

  List<String> _getFastIndexTokens(SongSortOption sortOption) {
    switch (sortOption) {
      case SongSortOption.dateAdded:
        // For date sorting, show years (dynamically generated from songs)
        return []; // Will be populated from actual data
      case SongSortOption.fileType:
        // For file type sorting, show common formats
        return ['FLAC', 'MP3', 'WAV', 'AAC', 'OGG', 'OGX', 'OPUS', 'ALAC', '#'];
      default:
        // For text-based sorting (title, artist, albumArtist)
        return SongFastIndexOverlay.defaultTokens;
    }
  }

  String _nearestIndexedToken(
    String token,
    Map<String, int> tokenToIndexMap,
    List<String> tokens,
  ) {
    if (tokenToIndexMap.containsKey(token)) {
      return token;
    }

    final start = tokens.indexOf(token);
    if (start == -1) return tokenToIndexMap.keys.first;

    for (var i = start + 1; i < tokens.length; i++) {
      final candidate = tokens[i];
      if (tokenToIndexMap.containsKey(candidate)) {
        return candidate;
      }
    }

    for (var i = start - 1; i >= 0; i--) {
      final candidate = tokens[i];
      if (tokenToIndexMap.containsKey(candidate)) {
        return candidate;
      }
    }

    return tokenToIndexMap.keys.first;
  }

  void _onFastIndexSelected({
    required List<Song> songs,
    required Map<String, int> tokenToIndexMap,
    required String token,
    required bool animate,
    required SongViewMode viewMode,
    required List<String> tokens,
  }) {
    if (songs.isEmpty || tokenToIndexMap.isEmpty) return;

    final resolvedToken = _nearestIndexedToken(token, tokenToIndexMap, tokens);
    final targetIndex = tokenToIndexMap[resolvedToken];
    if (targetIndex == null) return;

    _selectedFastToken = resolvedToken;

    if (mounted && targetIndex != _selectedIndex) {
      setState(() {
        _selectedIndex = targetIndex;
      });
    }

    if (viewMode == SongViewMode.list) {
      _jumpInList(targetIndex, animate);
      return;
    }

    _orbitScrollController.jumpToIndex(targetIndex, animate: animate);
  }

  void _jumpInList(int targetIndex, bool animate) {
    if (!_listScrollController.hasClients) return;

    final targetOffset = targetIndex * _listItemExtent;
    final clampedOffset = targetOffset.clamp(
      0.0,
      _listScrollController.position.maxScrollExtent,
    );

    if (animate) {
      _listScrollController.animateTo(
        clampedOffset,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } else {
      _listScrollController.jumpTo(clampedOffset);
    }
  }

  List<Song> _visibleSongsFromCache() {
    if (_searchQuery.isEmpty) {
      return _cachedSongs;
    }

    return _cachedSongs.where((song) {
      return song.title.toLowerCase().contains(_searchQuery) ||
          song.artist.toLowerCase().contains(_searchQuery);
    }).toList();
  }

  void _syncInterfaceToCurrentSong(Song? song, {bool animate = true}) {
    if (!mounted || song == null || _cachedSongs.isEmpty) {
      return;
    }

    final visibleSongs = _visibleSongsFromCache();
    final targetIndex = visibleSongs.indexWhere((candidate) {
      return candidate.id == song.id;
    });
    if (targetIndex == -1) return;

    _syncSelectedTokenForIndex(visibleSongs, targetIndex);

    if (targetIndex != _selectedIndex) {
      setState(() {
        _selectedIndex = targetIndex;
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final viewMode = ref.read(songsViewModeProvider);
      if (viewMode == SongViewMode.list) {
        _jumpInList(targetIndex, animate);
        return;
      }

      _orbitScrollController.jumpToIndex(targetIndex, animate: animate);
    });
  }

  void _alignCurrentSongAfterSongsLoad(List<Song> visibleSongs) {
    if (_alignedCurrentSongAfterLoad || visibleSongs.isEmpty) {
      return;
    }

    final currentSong = ref.read(currentSongProvider);
    if (currentSong == null) return;

    final targetIndex = visibleSongs.indexWhere(
      (song) => song.id == currentSong.id,
    );
    if (targetIndex == -1) return;

    _alignedCurrentSongAfterLoad = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncInterfaceToCurrentSong(currentSong, animate: false);
    });
  }

  void _syncSelectedTokenForIndex(List<Song> songs, int index) {
    if (songs.isEmpty || index < 0 || index >= songs.length) {
      return;
    }
    final songsAsync = ref.read(songsProvider);
    final sortOption =
        songsAsync.value?.sortOption ?? SongSortOption.albumArtist;
    _selectedFastToken = _tokenForSong(songs[index], sortOption);
  }

  Future<void> _playSongAndOpenPlayer({
    required List<Song> songs,
    required int index,
  }) async {
    // Always use the full unfiltered library (_cachedSongs) as the playlist
    // so shuffle works on all songs, not just search results
    final songToPlay = songs[index];
    await ref
        .read(playerProvider.notifier)
        .play(songToPlay, playlist: _cachedSongs);

    if (!mounted) return;

    // Navigate to full player screen using helper to prevent duplicates
    final result = await NavigationHelper.navigateToFullPlayer(
      context,
      heroTag: 'song_art_${songToPlay.id}',
    );

    // If a navigation index was returned and it's not Songs (1), notify parent to switch tabs
    if (result != null && result != 1 && widget.onNavigationRequested != null) {
      widget.onNavigationRequested!(result);
    }
  }

  Future<void> _queueSong(Song song) async {
    await ref.read(playerProvider.notifier).addToQueue(song);
    if (!mounted) return;
    _showSongActionSnackBar('Queued "${song.title}"');
  }

  Future<void> _favoriteSong(Song song) async {
    _showSongActionSnackBar('Added "${song.title}" to favorites');
    unawaited(() async {
      try {
        await ref.read(favoritesServiceProvider).addFavorite(song.id);
      } catch (error, stackTrace) {
        debugPrint('Failed to add favorite for ${song.id}: $error');
        debugPrintStack(stackTrace: stackTrace);
        if (!mounted) return;
        _showSongActionSnackBar('Failed to add "${song.title}" to favorites');
        return;
      }

      ref.invalidate(favoritesProvider);
    }());
  }

  void _showSongActionSnackBar(String message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.removeCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(milliseconds: 1600),
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppConstants.radiusMd),
          ),
        ),
      );
    });
  }

  Widget _buildLoadingState() {
    return Center(
      child: CircularProgressIndicator(color: context.adaptiveTextSecondary),
    );
  }

  Widget _buildErrorState(Object error) {
    return _ContentStateWidget(
      icon: LucideIcons.circleX,
      title: 'Error loading songs',
      subtitle: error.toString(),
      action: TextButton(
        onPressed: () => ref.invalidate(songsProvider),
        child: const Text('Retry'),
      ),
    );
  }

  Widget _buildEmptyState() {
    return const _ContentStateWidget(
      icon: LucideIcons.music4,
      title: 'No Music Yet',
      subtitle: 'Add a music folder in Settings',
    );
  }

  Widget _buildNoSearchResultsState() {
    return const _ContentStateWidget(
      icon: LucideIcons.searchX,
      title: 'No matches found',
      subtitle: 'Try adjusting your search query',
    );
  }

  Widget _buildAmbientBackground() {
    return Stack(
      children: [
        // Top-left glow
        Positioned(
          top: -100,
          left: -100,
          child: Container(
            width: 300,
            height: 300,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  Colors.white.withValues(alpha: 0.03),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),

        // Center-right glow (follows selected item area)
        Positioned(
          top: MediaQuery.of(context).size.height * 0.3,
          right: -50,
          child: Container(
            width: 200,
            height: 200,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  Colors.white.withValues(alpha: 0.02),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(AsyncValue<SongsState> songsAsync) {
    final songCount = songsAsync.value?.songs.length ?? 0;
    final currentSort =
        songsAsync.value?.sortOption ?? SongSortOption.albumArtist;
    final currentFilter =
        songsAsync.value?.fileTypeFilter ?? SongFileTypeFilter.all;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppConstants.spacingLg,
        vertical: AppConstants.spacingMd,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Your Library',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: context.adaptiveTextPrimary,
                ),
              ),
              const SizedBox(height: AppConstants.spacingXxs),
              Text(
                '$songCount songs',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: context.adaptiveTextSecondary,
                ),
              ),
            ],
          ),

          Row(
            children: [
              _buildHeaderIconButton(
                context: context,
                icon: LucideIcons.shuffle,
                onTap: () => _shufflePlayFromLibrary(songsAsync),
              ),
              const SizedBox(width: AppConstants.spacingSm),
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      AppColors.surfaceLight.withValues(alpha: 0.75),
                      AppColors.surface.withValues(alpha: 0.85),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(AppConstants.radiusMd),
                  border: Border.all(color: AppColors.glassBorder, width: 1),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 12,
                      spreadRadius: 1,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: PopupMenuButton<void>(
                  icon: Icon(
                    Icons.sort_rounded,
                    color: context.adaptiveTextSecondary,
                    size: context.responsiveIcon(AppConstants.iconSizeMd),
                  ),
                  color: AppColors.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppConstants.radiusMd),
                    side: const BorderSide(
                      color: AppColors.glassBorder,
                      width: 1,
                    ),
                  ),
                  onSelected: (dynamic result) {
                    if (result is SongSortOption) {
                      ref.read(songsProvider.notifier).setSortOption(result);
                      setState(() {
                        _selectedIndex = 0;
                      });
                    } else if (result is SongFileTypeFilter) {
                      ref
                          .read(songsProvider.notifier)
                          .setFileTypeFilter(result);
                      setState(() {
                        _selectedIndex = 0;
                      });
                    }
                  },
                  itemBuilder: (BuildContext context) => [
                    PopupMenuItem<void>(
                      enabled: false,
                      child: Text(
                        'SORT',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: context.adaptiveTextTertiary,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                    PopupMenuItem<SongSortOption>(
                      value: SongSortOption.albumArtist,
                      child: Row(
                        children: [
                          if (currentSort == SongSortOption.albumArtist)
                            const Icon(Icons.check, size: 18),
                          if (currentSort == SongSortOption.albumArtist)
                            const SizedBox(width: 8),
                          Text(
                            'Album Artist',
                            style: TextStyle(
                              color: context.adaptiveTextPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem<SongSortOption>(
                      value: SongSortOption.title,
                      child: Row(
                        children: [
                          if (currentSort == SongSortOption.title)
                            const Icon(Icons.check, size: 18),
                          if (currentSort == SongSortOption.title)
                            const SizedBox(width: 8),
                          Text(
                            'Title',
                            style: TextStyle(
                              color: context.adaptiveTextPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem<SongSortOption>(
                      value: SongSortOption.artist,
                      child: Row(
                        children: [
                          if (currentSort == SongSortOption.artist)
                            const Icon(Icons.check, size: 18),
                          if (currentSort == SongSortOption.artist)
                            const SizedBox(width: 8),
                          Text(
                            'Artist',
                            style: TextStyle(
                              color: context.adaptiveTextPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem<SongSortOption>(
                      value: SongSortOption.dateAdded,
                      child: Row(
                        children: [
                          if (currentSort == SongSortOption.dateAdded)
                            const Icon(Icons.check, size: 18),
                          if (currentSort == SongSortOption.dateAdded)
                            const SizedBox(width: 8),
                          Text(
                            'Date Added',
                            style: TextStyle(
                              color: context.adaptiveTextPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem<SongSortOption>(
                      value: SongSortOption.fileType,
                      child: Row(
                        children: [
                          if (currentSort == SongSortOption.fileType)
                            const Icon(Icons.check, size: 18),
                          if (currentSort == SongSortOption.fileType)
                            const SizedBox(width: 8),
                          Text(
                            'Format',
                            style: TextStyle(
                              color: context.adaptiveTextPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem<void>(
                      enabled: false,
                      child: Text(
                        'FILTER BY FORMAT',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: context.adaptiveTextTertiary,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                    PopupMenuItem<SongFileTypeFilter>(
                      value: SongFileTypeFilter.all,
                      child: Row(
                        children: [
                          if (currentFilter == SongFileTypeFilter.all)
                            const Icon(Icons.check, size: 18),
                          if (currentFilter == SongFileTypeFilter.all)
                            const SizedBox(width: 8),
                          Text(
                            'All Formats',
                            style: TextStyle(
                              color: context.adaptiveTextPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem<SongFileTypeFilter>(
                      value: SongFileTypeFilter.flac,
                      child: Row(
                        children: [
                          if (currentFilter == SongFileTypeFilter.flac)
                            const Icon(Icons.check, size: 18),
                          if (currentFilter == SongFileTypeFilter.flac)
                            const SizedBox(width: 8),
                          Text(
                            'FLAC',
                            style: TextStyle(
                              color: context.adaptiveTextPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem<SongFileTypeFilter>(
                      value: SongFileTypeFilter.mp3,
                      child: Row(
                        children: [
                          if (currentFilter == SongFileTypeFilter.mp3)
                            const Icon(Icons.check, size: 18),
                          if (currentFilter == SongFileTypeFilter.mp3)
                            const SizedBox(width: 8),
                          Text(
                            'MP3',
                            style: TextStyle(
                              color: context.adaptiveTextPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem<SongFileTypeFilter>(
                      value: SongFileTypeFilter.wav,
                      child: Row(
                        children: [
                          if (currentFilter == SongFileTypeFilter.wav)
                            const Icon(Icons.check, size: 18),
                          if (currentFilter == SongFileTypeFilter.wav)
                            const SizedBox(width: 8),
                          Text(
                            'WAV',
                            style: TextStyle(
                              color: context.adaptiveTextPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem<SongFileTypeFilter>(
                      value: SongFileTypeFilter.aac,
                      child: Row(
                        children: [
                          if (currentFilter == SongFileTypeFilter.aac)
                            const Icon(Icons.check, size: 18),
                          if (currentFilter == SongFileTypeFilter.aac)
                            const SizedBox(width: 8),
                          Text(
                            'AAC',
                            style: TextStyle(
                              color: context.adaptiveTextPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem<SongFileTypeFilter>(
                      value: SongFileTypeFilter.ogg,
                      child: Row(
                        children: [
                          if (currentFilter == SongFileTypeFilter.ogg)
                            const Icon(Icons.check, size: 18),
                          if (currentFilter == SongFileTypeFilter.ogg)
                            const SizedBox(width: 8),
                          Text(
                            'OGG',
                            style: TextStyle(
                              color: context.adaptiveTextPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem<SongFileTypeFilter>(
                      value: SongFileTypeFilter.alac,
                      child: Row(
                        children: [
                          if (currentFilter == SongFileTypeFilter.alac)
                            const Icon(Icons.check, size: 18),
                          if (currentFilter == SongFileTypeFilter.alac)
                            const SizedBox(width: 8),
                          Text(
                            'ALAC',
                            style: TextStyle(
                              color: context.adaptiveTextPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHeaderIconButton({
    required BuildContext context,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.surfaceLight.withValues(alpha: 0.75),
            AppColors.surface.withValues(alpha: 0.85),
          ],
        ),
        borderRadius: BorderRadius.circular(AppConstants.radiusMd),
        border: Border.all(color: AppColors.glassBorder, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 12,
            spreadRadius: 1,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: IconButton(
        onPressed: onTap,
        icon: Icon(
          icon,
          color: context.adaptiveTextSecondary,
          size: context.responsiveIcon(AppConstants.iconSizeMd),
        ),
      ),
    );
  }

  Future<void> _shufflePlayFromLibrary(
    AsyncValue<SongsState> songsAsync,
  ) async {
    final sourceSongs = songsAsync.value?.songs ?? const <Song>[];
    if (sourceSongs.isEmpty) return;

    final shuffledPlaylist = List<Song>.from(sourceSongs)..shuffle(Random());
    final randomSong = shuffledPlaylist.first;

    await ref
        .read(playerProvider.notifier)
        .play(randomSong, playlist: shuffledPlaylist);

    if (!mounted) return;

    final result = await NavigationHelper.navigateToFullPlayer(
      context,
      heroTag: 'song_art_${randomSong.id}',
    );

    if (result != null && result != 1 && widget.onNavigationRequested != null) {
      widget.onNavigationRequested!(result);
    }
  }
}

class _QueueSwipeListItem extends StatefulWidget {
  final Widget child;
  final Future<void> Function() onQueued;
  final Future<void> Function() onFavorited;

  const _QueueSwipeListItem({
    required this.child,
    required this.onQueued,
    required this.onFavorited,
  });

  @override
  State<_QueueSwipeListItem> createState() => _QueueSwipeListItemState();
}

class _QueueSwipeListItemState extends State<_QueueSwipeListItem> {
  double _dragDx = 0;
  bool _queuedFlash = false;
  bool _favoriteFlash = false;

  @override
  Widget build(BuildContext context) {
    final queueRevealProgress = (-_dragDx / 120).clamp(0.0, 1.0);
    final favoriteRevealProgress = (_dragDx / 120).clamp(0.0, 1.0);

    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppConstants.radiusLg),
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Colors.redAccent.withValues(
                    alpha: 0.14 + (favoriteRevealProgress * 0.14),
                  ),
                  AppColors.surface,
                  AppColors.accent.withValues(
                    alpha: 0.14 + (queueRevealProgress * 0.14),
                  ),
                ],
              ),
              border: Border.all(
                color: Color.lerp(
                  AppColors.accent.withValues(
                    alpha: 0.18 + (queueRevealProgress * 0.24),
                  ),
                  Colors.redAccent.withValues(
                    alpha: 0.18 + (favoriteRevealProgress * 0.24),
                  ),
                  favoriteRevealProgress,
                )!,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppConstants.spacingLg,
              ),
              child: Row(
                children: [
                  Opacity(
                    opacity: favoriteRevealProgress,
                    child: const Icon(
                      Icons.favorite_rounded,
                      color: Colors.redAccent,
                      size: 22,
                    ),
                  ),
                  const Spacer(),
                  Opacity(
                    opacity: queueRevealProgress,
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.queue_music_rounded,
                          color: AppColors.accent,
                          size: 20,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Add to queue',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        GestureDetector(
          onHorizontalDragUpdate: (details) {
            final nextDx = (_dragDx + details.delta.dx).clamp(-132.0, 132.0);
            if (nextDx != _dragDx) {
              setState(() {
                _dragDx = nextDx;
              });
            }
          },
          onHorizontalDragEnd: (details) async {
            final shouldFavorite =
                _dragDx >= 84 ||
                (details.primaryVelocity != null &&
                    details.primaryVelocity! > 400);
            final shouldQueue =
                _dragDx <= -84 ||
                (details.primaryVelocity != null &&
                    details.primaryVelocity! < -400);
            if (shouldFavorite) {
              setState(() {
                _dragDx = 0;
                _favoriteFlash = true;
              });
              await widget.onFavorited();
              if (!mounted) return;
              await Future<void>.delayed(const Duration(milliseconds: 180));
              if (!mounted) return;
              setState(() {
                _favoriteFlash = false;
              });
              return;
            }
            if (shouldQueue) {
              setState(() {
                _dragDx = 0;
                _queuedFlash = true;
              });
              await widget.onQueued();
              if (!mounted) return;
              await Future<void>.delayed(const Duration(milliseconds: 180));
              if (!mounted) return;
              setState(() {
                _queuedFlash = false;
              });
              return;
            }
            setState(() {
              _dragDx = 0;
            });
          },
          onHorizontalDragCancel: () {
            if (_dragDx != 0) {
              setState(() {
                _dragDx = 0;
              });
            }
          },
          behavior: HitTestBehavior.translucent,
          child: AnimatedSlide(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            offset: Offset(_dragDx / 360, 0),
            child: AnimatedScale(
              duration: const Duration(milliseconds: 180),
              scale: (_queuedFlash || _favoriteFlash) ? 0.985 : 1,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppConstants.radiusLg),
                  boxShadow: (_queuedFlash || _favoriteFlash)
                      ? [
                          BoxShadow(
                            color:
                                (_favoriteFlash
                                        ? Colors.redAccent
                                        : AppColors.accent)
                                    .withValues(alpha: 0.22),
                            blurRadius: 18,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
                child: widget.child,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ContentStateWidget extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;

  const _ContentStateWidget({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: context.responsiveIcon(AppConstants.containerSizeLg),
            color: context.adaptiveTextTertiary.withValues(alpha: 0.5),
          ),
          const SizedBox(height: AppConstants.spacingLg),
          Text(
            title,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: context.adaptiveTextSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppConstants.spacingSm),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: context.adaptiveTextTertiary,
            ),
            textAlign: TextAlign.center,
          ),
          if (action != null) ...[
            const SizedBox(height: AppConstants.spacingLg),
            action!,
          ],
        ],
      ),
    );
  }
}
