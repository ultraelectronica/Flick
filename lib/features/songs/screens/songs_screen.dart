import 'package:flutter/material.dart';
import 'package:flick_player/core/theme/app_colors.dart';
import 'package:flick_player/core/constants/app_constants.dart';
import 'package:flick_player/models/song.dart';
import 'package:flick_player/features/songs/widgets/orbit_scroll.dart';

/// Main songs screen with orbital scrolling.
class SongsScreen extends StatefulWidget {
  const SongsScreen({super.key});

  @override
  State<SongsScreen> createState() => _SongsScreenState();
}

class _SongsScreenState extends State<SongsScreen> {
  int _selectedIndex = 0;
  final List<Song> _songs = Song.sampleSongs;

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

                // Orbit scroll area
                Expanded(
                  child: OrbitScroll(
                    songs: _songs,
                    selectedIndex: _selectedIndex,
                    onSelectedIndexChanged: (index) {
                      setState(() {
                        _selectedIndex = index;
                      });
                    },
                    onSongSelected: (index) {
                      // Handle song tap - could play or show details
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
