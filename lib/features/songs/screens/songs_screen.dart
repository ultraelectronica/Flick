import 'package:flutter/material.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/models/song.dart';
import 'package:flick/features/songs/widgets/orbit_scroll.dart';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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

  @override
  void initState() {
    super.initState();
    _loadSongs();
    // Listen for changes in the songs collection
    _songRepository.watchSongs().listen((_) {
      _loadSongs();
    });
  }

  Future<void> _loadSongs() async {
    try {
      final songs = await _songRepository.getAllSongs();
      if (mounted) {
        setState(() {
          _songs = songs;
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
                          },
                          onSongSelected: (index) {
                            setState(() {
                              _selectedIndex = index;
                            });
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

          // Shuffle/Sort action buttons could go here
          Container(
            padding: const EdgeInsets.all(AppConstants.spacingSm),
            decoration: BoxDecoration(
              color: AppColors.glassBackground,
              borderRadius: BorderRadius.circular(AppConstants.radiusMd),
              border: Border.all(color: AppColors.glassBorder, width: 1),
            ),
            child: const Icon(
              Icons.shuffle_rounded,
              color: AppColors.textSecondary,
              size: 20,
            ),
          ),
        ],
      ),
    );
  }
}
