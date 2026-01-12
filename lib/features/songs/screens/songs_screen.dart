import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/models/song.dart';
import 'package:flick/features/songs/widgets/orbit_scroll.dart';
import 'package:flick/features/player/screens/full_player_screen.dart';
import 'package:flick/providers/providers.dart';
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

  @override
  void initState() {
    super.initState();
    // Listen to player changes to sync selection (handled in build via ref.listen)
  }

  @override
  Widget build(BuildContext context) {
    // Watch the songs provider for reactive updates
    final songsAsync = ref.watch(songsProvider);

    // Sync selection with currently playing song
    ref.listen<Song?>(currentSongProvider, (previous, next) {
      if (next != null) {
        final songs = ref.read(songsProvider).value?.sortedSongs ?? [];
        final index = songs.indexWhere((s) => s.id == next.id);
        if (index != -1 && index != _selectedIndex) {
          setState(() {
            _selectedIndex = index;
          });
        }
      }
    });

    return Stack(
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

              // Content based on async state
              Expanded(
                child: songsAsync.when(
                  loading: () => _buildLoadingState(),
                  error: (error, stack) => _buildErrorState(error),
                  data: (songsState) {
                    final songs = songsState.sortedSongs;

                    if (songs.isEmpty) {
                      return _buildEmptyState();
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

                        // Navigate to full player screen
                        final result = await Navigator.of(context).push<int>(
                          PageRouteBuilder(
                            pageBuilder:
                                (context, animation, secondaryAnimation) =>
                                    FullPlayerScreen(
                                      heroTag: 'song_art_${songs[index].id}',
                                    ),
                            transitionsBuilder:
                                (
                                  context,
                                  animation,
                                  secondaryAnimation,
                                  child,
                                ) {
                                  const begin = Offset(0.0, 1.0);
                                  const end = Offset.zero;
                                  const curve = Curves.easeOutCubic;

                                  var tween = Tween(
                                    begin: begin,
                                    end: end,
                                  ).chain(CurveTween(curve: curve));

                                  return SlideTransition(
                                    position: animation.drive(tween),
                                    child: child,
                                  );
                                },
                            transitionDuration: const Duration(
                              milliseconds: 300,
                            ),
                            opaque: false,
                            barrierColor: Colors.black,
                          ),
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
    );
  }

  Widget _buildLoadingState() {
    return Center(
      child: CircularProgressIndicator(color: context.adaptiveTextSecondary),
    );
  }

  Widget _buildErrorState(Object error) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            LucideIcons.circleX,
            size: context.responsiveIcon(AppConstants.containerSizeLg),
            color: context.adaptiveTextTertiary.withValues(alpha: 0.5),
          ),
          const SizedBox(height: AppConstants.spacingLg),
          Text(
            'Error loading songs',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: context.adaptiveTextSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppConstants.spacingSm),
          Text(
            error.toString(),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: context.adaptiveTextTertiary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppConstants.spacingLg),
          TextButton(
            onPressed: () => ref.invalidate(songsProvider),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            LucideIcons.music4,
            size: context.responsiveIcon(AppConstants.containerSizeLg),
            color: context.adaptiveTextTertiary.withValues(alpha: 0.5),
          ),
          const SizedBox(height: AppConstants.spacingLg),
          Text(
            'No Music Yet',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: context.adaptiveTextSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppConstants.spacingSm),
          Text(
            'Add a music folder in Settings',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: context.adaptiveTextTertiary,
            ),
          ),
        ],
      ),
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

          // Sort Button
          Container(
            decoration: BoxDecoration(
              color: AppColors.glassBackground,
              borderRadius: BorderRadius.circular(AppConstants.radiusMd),
              border: Border.all(color: AppColors.glassBorder, width: 1),
            ),
            child: PopupMenuButton<SongSortOption>(
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
              onSelected: (SongSortOption result) {
                ref.read(songsProvider.notifier).setSortOption(result);
                // Reset selection to top
                setState(() {
                  _selectedIndex = 0;
                });
              },
              itemBuilder: (BuildContext context) =>
                  <PopupMenuEntry<SongSortOption>>[
                    PopupMenuItem<SongSortOption>(
                      value: SongSortOption.title,
                      child: Row(
                        children: [
                          if (currentSort == SongSortOption.title)
                            const Icon(Icons.check, size: 18),
                          if (currentSort == SongSortOption.title)
                            const SizedBox(width: 8),
                          Text(
                            'Sort by Title',
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
                            'Sort by Artist',
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
                            'Sort by Date Added',
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
    );
  }
}
