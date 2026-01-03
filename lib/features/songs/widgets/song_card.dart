import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/models/song.dart';
import 'package:flick/widgets/common/marquee_widget.dart';

/// Song card widget for displaying in the orbit scroll.
class SongCard extends StatelessWidget {
  /// Song data to display
  final Song song;

  /// Scale factor based on position in orbit (0.0 - 1.0)
  final double scale;

  /// Opacity based on position in orbit (0.0 - 1.0)
  final double opacity;

  /// Whether this song is currently selected
  final bool isSelected;

  /// Callback when card is tapped
  final VoidCallback? onTap;

  const SongCard({
    super.key,
    required this.song,
    this.scale = 1.0,
    this.opacity = 1.0,
    this.isSelected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final artSize = isSelected
        ? AppConstants.songCardArtSizeLarge
        : AppConstants.songCardArtSize;

    // Width constraint based on design request
    final cardWidth = MediaQuery.of(context).size.width * 0.75;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedOpacity(
        duration: AppConstants.animationNormal,
        opacity: opacity,
        child: Transform.scale(
          scale: scale,
          child: SizedBox(
            width: cardWidth,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppConstants.radiusLg),
              child: Stack(
                children: [
                  // 1. Blurred Background Layer
                  if (isSelected && song.albumArt != null)
                    Positioned.fill(
                      child: ImageFiltered(
                        imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                        child: Container(
                          foregroundDecoration: BoxDecoration(
                            color: Colors.black.withValues(
                              alpha: 0.6,
                            ), // Darken
                          ),
                          child: _buildRawImage(
                            song.albumArt!,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    ),

                  // 2. Glass / Content Layer
                  BackdropFilter(
                    filter: ImageFilter.blur(
                      sigmaX: isSelected
                          ? 5.0
                          : AppConstants.glassBlurSigmaLight,
                      sigmaY: isSelected
                          ? 5.0
                          : AppConstants.glassBlurSigmaLight,
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(AppConstants.spacingSm),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? AppColors.glassBackgroundStrong.withValues(
                                alpha: 0.5,
                              ) // More transparent for blur to show
                            : AppColors.glassBackground,
                        borderRadius: BorderRadius.circular(
                          AppConstants.radiusLg,
                        ),
                        border: Border.all(
                          color: isSelected
                              ? AppColors.glassBorderStrong
                              : AppColors.glassBorder,
                          width: isSelected ? 1.5 : 1,
                        ),
                        boxShadow: isSelected
                            ? [
                                BoxShadow(
                                  color: Colors.white.withValues(alpha: 0.05),
                                  blurRadius: 20,
                                  spreadRadius: 0,
                                ),
                              ]
                            : null,
                      ),
                      child: Row(
                        children: [
                          // Album Art
                          _buildAlbumArt(artSize),

                          const SizedBox(width: AppConstants.spacingMd),

                          // Song Info
                          _buildSongInfo(context),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAlbumArt(double size) {
    return Hero(
      tag: 'song_art_${song.id}',
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppConstants.radiusMd),
          color: AppColors.surfaceLight,
          border: Border.all(color: AppColors.glassBorder, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppConstants.radiusMd),
          child: song.albumArt != null
              ? _buildRawImage(song.albumArt!, fit: BoxFit.cover)
              : _buildPlaceholderArt(),
        ),
      ),
    );
  }

  Widget _buildRawImage(String path, {BoxFit fit = BoxFit.cover}) {
    if (path.startsWith('http')) {
      return Image.network(
        path,
        fit: fit,
        errorBuilder: (context, error, stackTrace) => _buildPlaceholderArt(),
      );
    } else {
      return Image.file(
        File(path),
        fit: fit,
        errorBuilder: (context, error, stackTrace) => _buildPlaceholderArt(),
      );
    }
  }

  Widget _buildPlaceholderArt() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.surfaceLight, AppColors.surface],
        ),
      ),
      child: const Center(
        child: Icon(
          Icons.music_note_rounded,
          color: AppColors.textTertiary,
          size: 28,
        ),
      ),
    );
  }

  Widget _buildSongInfo(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Title with Marquee
          if (isSelected)
            SizedBox(
              height: 24,
              child: MarqueeWidget(
                child: Text(
                  song.title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            )
          else
            Text(
              song.title,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
                letterSpacing: 0.2,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),

          const SizedBox(height: AppConstants.spacingXxs),

          // Artist
          Text(
            song.artist,
            style: TextStyle(
              fontSize: isSelected ? 14 : 12,
              fontWeight: FontWeight.w400,
              color: AppColors.textSecondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),

          const SizedBox(height: AppConstants.spacingXs),

          // Metadata row: file type, duration, resolution
          Row(
            children: [
              _buildMetadataBadge(song.fileType),
              const SizedBox(width: AppConstants.spacingXs),
              _buildMetadataText(song.formattedDuration),
              if (song.resolution != null && song.resolution != 'Unknown') ...[
                const SizedBox(width: AppConstants.spacingXs),
                _buildMetadataText('•'),
                const SizedBox(width: AppConstants.spacingXs),
                Flexible(child: _buildMetadataText(song.resolution!)),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetadataBadge(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppConstants.spacingXs,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: AppColors.glassBackgroundStrong,
        borderRadius: BorderRadius.circular(AppConstants.radiusXs),
        border: Border.all(color: AppColors.glassBorder, width: 0.5),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: AppColors.accent,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildMetadataText(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w400,
        color: AppColors.textTertiary,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
