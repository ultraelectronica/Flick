import 'package:flutter/material.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/models/song.dart';
import 'package:flick/widgets/common/marquee_widget.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';

/// Song card widget for displaying in the orbit scroll.
class SongCard extends StatefulWidget {
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

  /// Callback when the card is swiped left.
  final VoidCallback? onSwipeLeft;

  /// Callback when the card is swiped right.
  final VoidCallback? onSwipeRight;

  const SongCard({
    super.key,
    required this.song,
    this.scale = 1.0,
    this.opacity = 1.0,
    this.isSelected = false,
    this.onTap,
    this.onSwipeLeft,
    this.onSwipeRight,
  });

  @override
  State<SongCard> createState() => _SongCardState();
}

class _SongCardState extends State<SongCard> {
  double _dragDx = 0;
  bool _queuedFlash = false;
  bool _favoriteFlash = false;

  @override
  Widget build(BuildContext context) {
    final artSize = widget.isSelected
        ? AppConstants.songCardArtSizeLarge
        : AppConstants.songCardArtSize;

    final cardWidth = MediaQuery.of(context).size.width * 0.68;
    final cardHeight = 130.0;
    final queueRevealProgress = (-_dragDx / 110).clamp(0.0, 1.0);
    final favoriteRevealProgress = (_dragDx / 110).clamp(0.0, 1.0);

    return RepaintBoundary(
      child: GestureDetector(
        onTap: widget.onTap,
        onHorizontalDragUpdate: (details) {
          final nextDx = (_dragDx + details.delta.dx).clamp(-120.0, 120.0);
          if (nextDx != _dragDx) {
            setState(() {
              _dragDx = nextDx;
            });
          }
        },
        onHorizontalDragEnd: (details) async {
          final shouldFavorite =
              _dragDx >= 80 ||
              (details.primaryVelocity != null &&
                  details.primaryVelocity! > 400);
          final shouldQueue =
              _dragDx <= -80 ||
              (details.primaryVelocity != null &&
                  details.primaryVelocity! < -400);
          if (shouldFavorite) {
            setState(() {
              _dragDx = 0;
              _favoriteFlash = true;
            });
            widget.onSwipeRight?.call();
            await Future<void>.delayed(const Duration(milliseconds: 180));
            if (!mounted) return;
            setState(() {
              _favoriteFlash = false;
            });
            return;
          }
          if (shouldQueue) {
            setState(() {
              _dragDx = 0;
              _queuedFlash = true;
            });
            widget.onSwipeLeft?.call();
            await Future<void>.delayed(const Duration(milliseconds: 180));
            if (!mounted) return;
            setState(() {
              _queuedFlash = false;
            });
            return;
          }
          setState(() {
            _dragDx = 0;
          });
        },
        onHorizontalDragCancel: () {
          if (_dragDx != 0) {
            setState(() {
              _dragDx = 0;
            });
          }
        },
        child: AnimatedOpacity(
          duration: AppConstants.animationNormal,
          opacity: widget.opacity,
          child: Transform.scale(
            scale: widget.scale,
            child: SizedBox(
              width: cardWidth,
              height: cardHeight,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(
                          AppConstants.radiusLg,
                        ),
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [
                            Colors.redAccent.withValues(
                              alpha: 0.14 + (favoriteRevealProgress * 0.14),
                            ),
                            AppColors.surface,
                            AppColors.accent.withValues(
                              alpha: 0.14 + (queueRevealProgress * 0.14),
                            ),
                          ],
                        ),
                        border: Border.all(
                          color: Color.lerp(
                            AppColors.accent.withValues(
                              alpha: 0.18 + (queueRevealProgress * 0.26),
                            ),
                            Colors.redAccent.withValues(
                              alpha: 0.18 + (favoriteRevealProgress * 0.26),
                            ),
                            favoriteRevealProgress,
                          )!,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppConstants.spacingLg,
                        ),
                        child: Row(
                          children: [
                            Opacity(
                              opacity: favoriteRevealProgress,
                              child: const Icon(
                                Icons.favorite_rounded,
                                color: Colors.redAccent,
                                size: 22,
                              ),
                            ),
                            const Spacer(),
                            Opacity(
                              opacity: queueRevealProgress,
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.queue_music_rounded,
                                    color: AppColors.accent,
                                    size: 20,
                                  ),
                                  SizedBox(width: 8),
                                  Text(
                                    'Add to queue',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  AnimatedSlide(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    offset: Offset(_dragDx / cardWidth, 0),
                    child: AnimatedScale(
                      duration: const Duration(milliseconds: 180),
                      scale: (_queuedFlash || _favoriteFlash) ? 0.98 : 1,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(
                            AppConstants.radiusLg,
                          ),
                          boxShadow: (_queuedFlash || _favoriteFlash)
                              ? [
                                  BoxShadow(
                                    color:
                                        (_favoriteFlash
                                                ? Colors.redAccent
                                                : AppColors.accent)
                                            .withValues(alpha: 0.25),
                                    blurRadius: 18,
                                    spreadRadius: 1,
                                  ),
                                ]
                              : null,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(
                            AppConstants.radiusLg,
                          ),
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: _buildAlbumWithGradient(artSize),
                              ),
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
                                  padding: const EdgeInsets.all(
                                    AppConstants.spacingMd,
                                  ),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: artSize + AppConstants.spacingMd,
                                      ),
                                      Expanded(
                                        child: _buildSongInfo(
                                          context,
                                          isSelected: widget.isSelected,
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
                ],
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
        _buildRawImage(
          widget.song.albumArt ?? '',
          audioSourcePath: widget.song.filePath,
          fit: BoxFit.cover,
          artSize: size,
        ),
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
    String? audioSourcePath,
    BoxFit fit = BoxFit.cover,
    required double artSize,
  }) {
    final isThumbnail = artSize <= AppConstants.songCardArtSize;

    return CachedImageWidget(
      imagePath: path,
      audioSourcePath: audioSourcePath,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isSelected)
          SizedBox(
            height: 24,
            child: MarqueeWidget(
              child: Text(
                widget.song.title,
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
            widget.song.title,
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
        Text(
          widget.song.artist,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w400,
            color: Colors.white70,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AppConstants.spacingXs),
        Row(
          children: [
            _buildMetadataBadge(widget.song.fileType),
            const SizedBox(width: AppConstants.spacingXs),
            _buildMetadataText(widget.song.formattedDuration),
            if (widget.song.resolution != null &&
                widget.song.resolution != 'Unknown') ...[
              const SizedBox(width: AppConstants.spacingXs),
              _buildMetadataText('•'),
              const SizedBox(width: AppConstants.spacingXs),
              Flexible(child: _buildMetadataText(widget.song.resolution!)),
            ],
          ],
        ),
      ],
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
