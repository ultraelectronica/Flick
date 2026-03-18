import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/core/utils/navigation_helper.dart';
import 'package:flick/models/song.dart';
import 'package:flick/features/songs/widgets/orbit_scroll.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/widgets/common/glass_search_bar.dart';
import 'package:flick/widgets/common/display_mode_wrapper.dart';
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
  int _selectedIndex = 0;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  List<Song> _cachedSongs = [];

  @override
  void initState() {
    super.initState();
    ref.listen<Song?>(currentSongProvider, (previous, next) {
      if (next != null && mounted) {
        final index = _cachedSongs.indexWhere((s) => s.id == next.id);
        if (index != -1 && index != _selectedIndex) {
          setState(() {
            _selectedIndex = index;
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final songsAsync = ref.watch(songsProvider);

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
                      var songs = songsState.sortedSongs;
                      _cachedSongs = songs;

                      if (_searchQuery.isNotEmpty) {
                        songs = songs.where((song) {
                          return song.title.toLowerCase().contains(
                                _searchQuery,
                              ) ||
                              song.artist.toLowerCase().contains(_searchQuery);
                        }).toList();
                        _cachedSongs = songs;
                      }

                      if (songs.isEmpty && _searchQuery.isEmpty) {
                        return _buildEmptyState();
                      }

                      if (songs.isEmpty && _searchQuery.isNotEmpty) {
                        return _buildNoSearchResultsState();
                      }

                      // Ensure selected index is valid
                      if (_selectedIndex >= songs.length) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) {
                            setState(() => _selectedIndex = 0);
                          }
                        });
                      }

                      return OrbitScroll(
                        songs: songs,
                        selectedIndex: _selectedIndex
                            .clamp(0, songs.length - 1)
                            .toInt(),
                        onSelectedIndexChanged: (index) {
                          setState(() {
                            _selectedIndex = index;
                          });
                        },
                        onSongSelected: (index) async {
                          // Play the song with the full playlist context
                          await ref
                              .read(playerProvider.notifier)
                              .play(songs[index], playlist: songs);

                          if (!context.mounted) return;

                          // Navigate to full player screen using helper to prevent duplicates
                          final result =
                              await NavigationHelper.navigateToFullPlayer(
                                context,
                                heroTag: 'song_art_${songs[index].id}',
                              );

                          // If a navigation index was returned and it's not Songs (1),
                          // notify the parent to switch tabs
                          if (result != null &&
                              result != 1 &&
                              widget.onNavigationRequested != null) {
                            widget.onNavigationRequested!(result);
                          }
                        },
                      );
                    },
                  ),
                ),

                // Space for nav bar & mini player
                const SizedBox(height: AppConstants.navBarHeight + 90),
              ],
            ),
          ),
        ],
      ),
    );
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
    final currentSort = songsAsync.value?.sortOption ?? SongSortOption.title;
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

          // Sort/Filter Button
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
                side: const BorderSide(color: AppColors.glassBorder, width: 1),
              ),
              onSelected: (dynamic result) {
                if (result is SongSortOption) {
                  ref.read(songsProvider.notifier).setSortOption(result);
                } else if (result is SongFileTypeFilter) {
                  ref.read(songsProvider.notifier).setFileTypeFilter(result);
                }
                setState(() {
                  _selectedIndex = 0;
                });
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
                  value: SongSortOption.title,
                  child: Row(
                    children: [
                      if (currentSort == SongSortOption.title)
                        const Icon(Icons.check, size: 18),
                      if (currentSort == SongSortOption.title)
                        const SizedBox(width: 8),
                      Text(
                        'Title',
                        style: TextStyle(color: context.adaptiveTextPrimary),
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
                        style: TextStyle(color: context.adaptiveTextPrimary),
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
                        style: TextStyle(color: context.adaptiveTextPrimary),
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
                        style: TextStyle(color: context.adaptiveTextPrimary),
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
                        style: TextStyle(color: context.adaptiveTextPrimary),
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
                        style: TextStyle(color: context.adaptiveTextPrimary),
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
                        style: TextStyle(color: context.adaptiveTextPrimary),
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
                        style: TextStyle(color: context.adaptiveTextPrimary),
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
                        style: TextStyle(color: context.adaptiveTextPrimary),
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
                        style: TextStyle(color: context.adaptiveTextPrimary),
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
                        style: TextStyle(color: context.adaptiveTextPrimary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
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
