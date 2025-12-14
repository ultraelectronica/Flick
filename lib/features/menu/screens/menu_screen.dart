import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick_player/core/theme/app_colors.dart';
import 'package:flick_player/core/constants/app_constants.dart';

/// Menu screen with navigation options matching the design language.
class MenuScreen extends StatelessWidget {
  const MenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(gradient: AppColors.backgroundGradient),
      child: SafeArea(
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
                      onTap: () {},
                    ),
                    _buildMenuItem(
                      context,
                      icon: LucideIcons.listMusic,
                      title: 'Playlists',
                      subtitle: 'Create and manage playlists',
                      onTap: () {},
                    ),
                    _buildMenuItem(
                      context,
                      icon: LucideIcons.heart,
                      title: 'Favorites',
                      subtitle: 'Your liked songs',
                      onTap: () {},
                    ),
                    _buildMenuItem(
                      context,
                      icon: LucideIcons.clock,
                      title: 'Recently Played',
                      subtitle: 'Jump back into your music',
                      onTap: () {},
                    ),
                    _buildMenuItem(
                      context,
                      icon: LucideIcons.folder,
                      title: 'Folders',
                      subtitle: 'Browse by folder structure',
                      onTap: () {},
                    ),
                    _buildMenuItem(
                      context,
                      icon: LucideIcons.disc,
                      title: 'Albums',
                      subtitle: 'Browse by album',
                      onTap: () {},
                    ),
                    _buildMenuItem(
                      context,
                      icon: LucideIcons.users,
                      title: 'Artists',
                      subtitle: 'Browse by artist',
                      onTap: () {},
                    ),

                    // Spacing for nav bar
                    const SizedBox(height: AppConstants.navBarHeight + 60),
                  ],
                ),
              ),
            ),
          ],
        ),
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
        style: Theme.of(
          context,
        ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
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
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppConstants.radiusLg),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppConstants.radiusLg),
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: AppConstants.glassBlurSigmaLight,
                sigmaY: AppConstants.glassBlurSigmaLight,
              ),
              child: Container(
                padding: const EdgeInsets.all(AppConstants.spacingMd),
                decoration: BoxDecoration(
                  color: AppColors.glassBackground,
                  borderRadius: BorderRadius.circular(AppConstants.radiusLg),
                  border: Border.all(color: AppColors.glassBorder, width: 1),
                ),
                child: Row(
                  children: [
                    // Icon container
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: AppColors.glassBackgroundStrong,
                        borderRadius: BorderRadius.circular(
                          AppConstants.radiusMd,
                        ),
                        border: Border.all(
                          color: AppColors.glassBorder,
                          width: 1,
                        ),
                      ),
                      child: Icon(icon, color: AppColors.textPrimary, size: 22),
                    ),

                    const SizedBox(width: AppConstants.spacingMd),

                    // Text content
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: AppColors.textTertiary),
                          ),
                        ],
                      ),
                    ),

                    // Arrow
                    const Icon(
                      LucideIcons.chevronRight,
                      color: AppColors.textTertiary,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
