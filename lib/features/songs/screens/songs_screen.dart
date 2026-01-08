import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/models/song.dart';
import 'package:flick/features/songs/widgets/orbit_scroll.dart';
import 'package:flick/features/player/screens/full_player_screen.dart';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/services/player_service.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

enum SortOption { title, artist, dateAdded }

/// Main songs screen with orbital scrolling.
class SongsScreen extends StatefulWidget {
  /// Callback when navigation to a different tab is requested from full player
  final ValueChanged<int>? onNavigationRequested;

  const SongsScreen({super.key, this.onNavigationRequested});

  @override
  State<SongsScreen> createState() => _SongsScreenState();
}

class _SongsScreenState extends State<SongsScreen> {
  int _selectedIndex = 0;
  List<Song> _songs = [];
  bool _isLoading = true;
  final SongRepository _songRepository = SongRepository();

  final PlayerService _playerService = PlayerService();

  // Sorting
  SortOption _currentSort = SortOption.title;

  // Timer for auto-play debounce
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _loadSongs();

    // Listen for changes in the songs collection
    _songRepository.watchSongs().listen((_) {
      _loadSongs();
    });

    // Listen to global player state to sync selection?
    // Optionally we can sync _selectedIndex to currently playing song.
    _playerService.currentSongNotifier.addListener(_syncSelectionWithPlayer);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _playerService.currentSongNotifier.removeListener(_syncSelectionWithPlayer);
    super.dispose();
  }

  void _syncSelectionWithPlayer() {
    final playing = _playerService.currentSongNotifier.value;
    if (playing != null) {
      final index = _songs.indexWhere((s) => s.id == playing.id);
      if (index != -1 && index != _selectedIndex && mounted) {
        setState(() {
          _selectedIndex = index;
        });
      }
    }
  }

  Future<void> _loadSongs() async {
    try {
      final songs = await _songRepository.getAllSongs();
      if (mounted) {
        setState(() {
          _songs = songs;
          _sortSongs(); // Apply current sort
          _isLoading = false;
          // Reset selected index if out of bounds
          if (_selectedIndex >= songs.length && songs.isNotEmpty) {
            _selectedIndex = 0;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _songs = Song.sampleSongs;
          _isLoading = false;
        });
      }
    }
  }

  void _sortSongs() {
    setState(() {
      switch (_currentSort) {
        case SortOption.title:
          _songs.sort((a, b) => a.title.compareTo(b.title));
          break;
        case SortOption.artist:
          _songs.sort((a, b) => a.artist.compareTo(b.artist));
          break;
        case SortOption.dateAdded:
          _songs.sort((a, b) {
            final dateA = a.dateAdded ?? DateTime.fromMillisecondsSinceEpoch(0);
            final dateB = b.dateAdded ?? DateTime.fromMillisecondsSinceEpoch(0);
            return dateB.compareTo(dateA); // Newest first
          });
          break;
      }
    });
  }

  Future<void> _playSong(Song song) async {
    await _playerService.play(song, playlist: _songs);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Background ambient effects
        _buildAmbientBackground(),

        // Main content
        SafeArea(
          bottom: false,
          child: Column(
            children: [
              // Header
              _buildHeader(),

              // Content based on state
              Expanded(
                child: _isLoading
                    ? _buildLoadingState()
                    : _songs.isEmpty
                    ? _buildEmptyState()
                    : OrbitScroll(
                        songs: _songs,
                        selectedIndex: _selectedIndex,
                        onSelectedIndexChanged: (index) {
                          setState(() {
                            _selectedIndex = index;
                          });
                        },
                        onSongSelected: (index) async {
                          _playSong(_songs[index]);
                          // Navigate to full player screen
                          final result = await Navigator.of(context).push<int>(
                            PageRouteBuilder(
                              pageBuilder:
                                  (context, animation, secondaryAnimation) =>
                                      FullPlayerScreen(
                                        heroTag: 'song_art_${_songs[index].id}',
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

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            LucideIcons.music4,
            size: 64,
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

  Widget _buildHeader() {
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
                '${_songs.length} songs',
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
            child: PopupMenuButton<SortOption>(
              icon: Icon(
                Icons.sort_rounded,
                color: context.adaptiveTextSecondary,
                size: 20,
              ),
              color: AppColors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppConstants.radiusMd),
                side: const BorderSide(color: AppColors.glassBorder, width: 1),
              ),
              onSelected: (SortOption result) {
                setState(() {
                  _currentSort = result;
                  _sortSongs();
                  // Reset selection to top or keep? Top is safer.
                  _selectedIndex = 0;
                });
              },
              itemBuilder: (BuildContext context) =>
                  <PopupMenuEntry<SortOption>>[
                    PopupMenuItem<SortOption>(
                      value: SortOption.title,
                      child: Text(
                        'Sort by Title',
                        style: TextStyle(color: context.adaptiveTextPrimary),
                      ),
                    ),
                    PopupMenuItem<SortOption>(
                      value: SortOption.artist,
                      child: Text(
                        'Sort by Artist',
                        style: TextStyle(color: context.adaptiveTextPrimary),
                      ),
                    ),
                    PopupMenuItem<SortOption>(
                      value: SortOption.dateAdded,
                      child: Text(
                        'Sort by Date Added',
                        style: TextStyle(color: context.adaptiveTextPrimary),
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
