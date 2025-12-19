import 'dart:async';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/models/song.dart';
import 'package:flick/features/songs/widgets/orbit_scroll.dart';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

enum SortOption { title, artist, dateAdded }

/// Main songs screen with orbital scrolling.
class SongsScreen extends StatefulWidget {
  const SongsScreen({super.key});

  @override
  State<SongsScreen> createState() => _SongsScreenState();
}

class _SongsScreenState extends State<SongsScreen> {
  int _selectedIndex = 0;
  List<Song> _songs = [];
  bool _isLoading = true;
  final SongRepository _songRepository = SongRepository();

  // Audio Player for Preview
  final AudioPlayer _player = AudioPlayer();
  String? _playingFilePath;
  bool _isPlaying = false;

  // Sorting
  SortOption _currentSort = SortOption.title;

  // Timer for auto-play debounce
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _loadSongs();

    // Listen to player state
    _player.playerStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state.playing;
          if (state.processingState == ProcessingState.completed) {
            _isPlaying = false;
            _playingFilePath = null;
          }
        });
      }
    });

    // Listen for changes in the songs collection
    _songRepository.watchSongs().listen((_) {
      _loadSongs();
    });
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _player.dispose();
    super.dispose();
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
      // If database not ready, use sample songs for now
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

  Future<void> _playPreview(Song song) async {
    try {
      final path = song.filePath;
      if (path == null) return;

      // If already playing this song, do nothing (maintain playback)
      if (_playingFilePath == path && _isPlaying) return;

      // Use AudioSource.uri to handle both file:// and content:// correctly
      await _player.setAudioSource(AudioSource.uri(Uri.parse(path)));
      await _player.play();
      setState(() {
        _playingFilePath = path;
      });
    } catch (e) {
      debugPrint("Error playing preview: $e");
    }
  }

  Future<void> _togglePreview(Song song) async {
    try {
      final path = song.filePath;
      if (path == null) return;

      if (_playingFilePath == path && _isPlaying) {
        await _player.pause();
      } else {
        // Use AudioSource.uri to handle both file:// and content:// correctly
        await _player.setAudioSource(AudioSource.uri(Uri.parse(path)));
        await _player.play();
        setState(() {
          _playingFilePath = path;
        });
      }
    } catch (e) {
      debugPrint("Error playing preview: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to play preview: ${e.toString()}')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(gradient: AppColors.backgroundGradient),
      child: Stack(
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

                            // Auto-play preview with debounce
                            _debounceTimer?.cancel();
                            _debounceTimer = Timer(
                              const Duration(milliseconds: 800),
                              () {
                                if (mounted && index < _songs.length) {
                                  _playPreview(_songs[index]);
                                }
                              },
                            );
                          },
                          onSongSelected: (index) {
                            if (_selectedIndex == index) {
                              // Tap on already selected song -> Toggle Preview
                              _togglePreview(_songs[index]);
                            } else {
                              setState(() {
                                _selectedIndex = index;
                              });
                            }
                          },
                        ),
                ),

                // Space for nav bar
                const SizedBox(height: AppConstants.navBarHeight + 40),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingState() {
    return const Center(
      child: CircularProgressIndicator(color: AppColors.textSecondary),
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
            color: AppColors.textTertiary.withValues(alpha: 0.5),
          ),
          const SizedBox(height: AppConstants.spacingLg),
          Text(
            'No Music Yet',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppConstants.spacingSm),
          Text(
            'Add a music folder in Settings',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: AppColors.textTertiary),
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
                ),
              ),
              const SizedBox(height: AppConstants.spacingXxs),
              Text(
                '${_songs.length} songs',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
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
              icon: const Icon(
                Icons.sort_rounded,
                color: AppColors.textSecondary,
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
                    const PopupMenuItem<SortOption>(
                      value: SortOption.title,
                      child: Text(
                        'Sort by Title',
                        style: TextStyle(color: AppColors.textPrimary),
                      ),
                    ),
                    const PopupMenuItem<SortOption>(
                      value: SortOption.artist,
                      child: Text(
                        'Sort by Artist',
                        style: TextStyle(color: AppColors.textPrimary),
                      ),
                    ),
                    const PopupMenuItem<SortOption>(
                      value: SortOption.dateAdded,
                      child: Text(
                        'Sort by Date Added',
                        style: TextStyle(color: AppColors.textPrimary),
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
