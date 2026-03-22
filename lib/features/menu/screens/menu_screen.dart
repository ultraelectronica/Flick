import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/features/songs/screens/songs_screen.dart';
import 'package:flick/features/playlists/screens/playlists_screen.dart';
import 'package:flick/features/favorites/screens/favorites_screen.dart';
import 'package:flick/features/recently_played/screens/recently_played_screen.dart';
import 'package:flick/features/folders/screens/folders_screen.dart';
import 'package:flick/features/albums/screens/albums_screen.dart';
import 'package:flick/features/artists/screens/artists_screen.dart';

/// Menu screen with navigation options matching the design language.
class MenuScreen extends StatelessWidget {
  /// Callback to navigate to a specific tab index in the main shell
  final ValueChanged<int>? onNavigateToTab;

  const MenuScreen({super.key, this.onNavigateToTab});

  void _navigateTo(BuildContext context, Widget screen) {
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => screen,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curvedAnimation = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );

          final slideAnimation = Tween<Offset>(
            begin: const Offset(0.06, 0.0),
            end: Offset.zero,
          ).animate(curvedAnimation);

          return FadeTransition(
            opacity: curvedAnimation,
            child: SlideTransition(position: slideAnimation, child: child),
          );
        },
        transitionDuration: AppConstants.animationNormal,
        reverseTransitionDuration: AppConstants.animationFast,
        opaque: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          _buildHeader(context),

          const SizedBox(height: AppConstants.spacingLg),

          // Menu items
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: AppConstants.spacingMd,
              ),
              child: Column(
                children: [
                  _buildMenuItem(
                    context,
                    icon: LucideIcons.library,
                    title: 'Library',
                    subtitle: 'All your music in one place',
                    onTap: () {
                      // Navigate to Songs tab (index 1) via callback
                      if (onNavigateToTab != null) {
                        onNavigateToTab!(1);
                      } else {
                        _navigateTo(context, const SongsScreen());
                      }
                    },
                  ),
                  _buildMenuItem(
                    context,
                    icon: LucideIcons.listMusic,
                    title: 'Playlists',
                    subtitle: 'Create and manage playlists',
                    onTap: () => _navigateTo(context, const PlaylistsScreen()),
                  ),
                  _buildMenuItem(
                    context,
                    icon: LucideIcons.heart,
                    title: 'Favorites',
                    subtitle: 'Your liked songs',
                    onTap: () => _navigateTo(context, const FavoritesScreen()),
                  ),
                  _buildMenuItem(
                    context,
                    icon: LucideIcons.clock,
                    title: 'Recently Played',
                    subtitle: 'Jump back into your music',
                    onTap: () =>
                        _navigateTo(context, const RecentlyPlayedScreen()),
                  ),
                  _buildMenuItem(
                    context,
                    icon: LucideIcons.folder,
                    title: 'Folders',
                    subtitle: 'Browse by folder structure',
                    onTap: () => _navigateTo(context, const FoldersScreen()),
                  ),
                  _buildMenuItem(
                    context,
                    icon: LucideIcons.disc,
                    title: 'Albums',
                    subtitle: 'Browse by album',
                    onTap: () => _navigateTo(context, const AlbumsScreen()),
                  ),
                  _buildMenuItem(
                    context,
                    icon: LucideIcons.users,
                    title: 'Artists',
                    subtitle: 'Browse by artist',
                    onTap: () => _navigateTo(context, const ArtistsScreen()),
                  ),

                  // Spacing for nav bar with mini player
                  const SizedBox(height: AppConstants.navBarHeight + 120),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppConstants.spacingLg,
        vertical: AppConstants.spacingMd,
      ),
      child: Text(
        'Menu',
        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: context.adaptiveTextPrimary,
        ),
      ),
    );
  }

  Widget _buildMenuItem(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppConstants.spacingSm),
      child: Material(
        color: AppColors.surface.withValues(alpha: 0.6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusLg),
          side: const BorderSide(color: AppColors.glassBorder, width: 1),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppConstants.radiusLg),
          child: Padding(
            padding: const EdgeInsets.all(AppConstants.spacingMd),
            child: Row(
              children: [
                // Icon container
                Container(
                  width: context.scaleSize(AppConstants.containerSizeMd),
                  height: context.scaleSize(AppConstants.containerSizeMd),
                  decoration: BoxDecoration(
                    color: AppColors.glassBackgroundStrong,
                    borderRadius: BorderRadius.circular(AppConstants.radiusMd),
                    border: Border.all(color: AppColors.glassBorder, width: 1),
                  ),
                  child: Icon(
                    icon,
                    color: context.adaptiveTextPrimary,
                    size: context.responsiveIcon(AppConstants.iconSizeMd),
                  ),
                ),

                const SizedBox(width: AppConstants.spacingMd),

                // Text content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(color: context.adaptiveTextPrimary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: context.adaptiveTextTertiary,
                        ),
                      ),
                    ],
                  ),
                ),

                // Arrow
                Icon(
                  LucideIcons.chevronRight,
                  color: context.adaptiveTextTertiary,
                  size: context.responsiveIcon(AppConstants.iconSizeMd),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
