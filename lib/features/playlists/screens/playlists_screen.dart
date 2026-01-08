import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';

/// Playlists screen with glassmorphic playlist cards.
class PlaylistsScreen extends StatelessWidget {
  const PlaylistsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(context),
            Expanded(child: _buildEmptyState(context)),
          ],
        ),
      ),
      floatingActionButton: _buildCreateButton(context),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppConstants.spacingLg,
        vertical: AppConstants.spacingMd,
      ),
      child: Row(
        children: [
          Container(
            decoration: BoxDecoration(
              color: AppColors.glassBackground,
              borderRadius: BorderRadius.circular(AppConstants.radiusMd),
              border: Border.all(color: AppColors.glassBorder),
            ),
            child: IconButton(
              icon: Icon(
                LucideIcons.arrowLeft,
                color: context.adaptiveTextPrimary,
                size: 20,
              ),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          const SizedBox(width: AppConstants.spacingMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Playlists',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: context.adaptiveTextPrimary,
                  ),
                ),
                Text(
                  'Your custom collections',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.adaptiveTextTertiary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppConstants.spacingXl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Animated stack of cards illustration
            SizedBox(
              height: 120,
              width: 140,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Back card
                  Positioned(
                    top: 20,
                    child: Transform.rotate(
                      angle: 0.1,
                      child: _buildIllustrationCard(
                        context,
                        AppColors.glassBackground.withValues(alpha: 0.3),
                      ),
                    ),
                  ),
                  // Middle card
                  Positioned(
                    top: 10,
                    child: Transform.rotate(
                      angle: -0.05,
                      child: _buildIllustrationCard(
                        context,
                        AppColors.glassBackground.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                  // Front card
                  _buildIllustrationCard(context, AppColors.glassBackground),
                ],
              ),
            ),
            const SizedBox(height: AppConstants.spacingXl),
            Text(
              'No Playlists Yet',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: context.adaptiveTextSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: AppConstants.spacingSm),
            Text(
              'Create your first playlist to organize\nyour favorite songs',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: context.adaptiveTextTertiary,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIllustrationCard(BuildContext context, Color color) {
    return Container(
      width: 100,
      height: 80,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppConstants.radiusMd),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Center(
        child: Icon(
          LucideIcons.listMusic,
          color: context.adaptiveTextTertiary.withValues(alpha: 0.5),
          size: 32,
        ),
      ),
    );
  }

  Widget _buildCreateButton(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppConstants.radiusRound),
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: AppConstants.glassBlurSigmaLight,
          sigmaY: AppConstants.glassBlurSigmaLight,
        ),
        child: FloatingActionButton.extended(
          onPressed: () {
            _showCreatePlaylistDialog(context);
          },
          backgroundColor: AppColors.glassBackgroundStrong,
          foregroundColor: context.adaptiveTextPrimary,
          elevation: 0,
          icon: const Icon(LucideIcons.plus),
          label: const Text(
            'Create Playlist',
            style: TextStyle(fontFamily: 'ProductSans'),
          ),
        ),
      ),
    );
  }

  void _showCreatePlaylistDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        ),
        title: Text(
          'Create Playlist',
          style: TextStyle(color: context.adaptiveTextPrimary),
        ),
        content: TextField(
          autofocus: true,
          style: TextStyle(color: context.adaptiveTextPrimary),
          decoration: InputDecoration(
            hintText: 'Playlist name',
            hintStyle: TextStyle(color: context.adaptiveTextTertiary),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AppColors.glassBorder),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: context.adaptiveTextSecondary),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Cancel',
              style: TextStyle(color: context.adaptiveTextTertiary),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Playlists coming soon!')),
              );
            },
            child: Text(
              'Create',
              style: TextStyle(color: context.adaptiveTextPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
