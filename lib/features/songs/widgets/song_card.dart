import 'package:flutter/material.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/models/song.dart';
import 'package:flick/widgets/common/marquee_widget.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';

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

    final cardWidth = MediaQuery.of(context).size.width * 0.68;
    final cardHeight = 130.0;

    return RepaintBoundary(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedOpacity(
          duration: AppConstants.animationNormal,
          opacity: opacity,
          child: Transform.scale(
            scale: scale,
            child: SizedBox(
              width: cardWidth,
              height: cardHeight,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppConstants.radiusLg),
                child: Stack(
                  children: [
                    // Album art with gradient overlay
                    Positioned.fill(child: _buildAlbumWithGradient(artSize)),

                    // Text content with darkening overlay for readability
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(
                            AppConstants.radiusLg,
                          ),
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.85),
                            ],
                            stops: const [0.25, 0.70],
                          ),
                        ),
                        padding: const EdgeInsets.all(AppConstants.spacingMd),
                        child: Row(
                          children: [
                            // Spacer to push text to the right
                            SizedBox(width: artSize + AppConstants.spacingMd),
                            Expanded(
                              child: _buildSongInfo(
                                context,
                                isSelected: isSelected,
                              ),
                            ),
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
      ),
    );
  }

  Widget _buildAlbumWithGradient(double size) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Album art or placeholder
        if (song.albumArt != null)
          _buildRawImage(song.albumArt!, fit: BoxFit.cover, artSize: size)
        else
          _buildPlaceholderArt(),

        // Gradient overlay: album art to semi-transparent background
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [Colors.transparent, Colors.black.withValues(alpha: 0.6)],
              stops: const [0.5, 1.0],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRawImage(
    String path, {
    BoxFit fit = BoxFit.cover,
    required double artSize,
  }) {
    // Use thumbnail for smaller album art sizes to improve performance
    final isThumbnail = artSize <= AppConstants.songCardArtSize;

    return CachedImageWidget(
      imagePath: path,
      fit: fit,
      placeholder: _buildPlaceholderArt(),
      errorWidget: _buildPlaceholderArt(),
      useThumbnail: isThumbnail,
      thumbnailWidth: isThumbnail
          ? (AppConstants.songCardArtSize * 2).toInt()
          : null,
      thumbnailHeight: isThumbnail
          ? (AppConstants.songCardArtSize * 2).toInt()
          : null,
    );
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

  Widget _buildSongInfo(BuildContext context, {bool isSelected = false}) {
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
                    color: Colors.white,
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
                color: Colors.white,
                letterSpacing: 0.2,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),

          const SizedBox(height: AppConstants.spacingXxs),

          // Artist - white for visibility
          Text(
            song.artist,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              color: Colors.white70,
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
        color: Colors.white24,
        borderRadius: BorderRadius.circular(AppConstants.radiusXs),
        border: Border.all(color: Colors.white30, width: 0.5),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: Colors.white,
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
        color: Colors.white70,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
