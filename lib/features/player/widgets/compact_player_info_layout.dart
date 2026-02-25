import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/favorites_service.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';

class CompactPlayerInfoLayout extends StatefulWidget {
  final Song song;
  final Object heroTag;
  final PlayerService playerService;
  final FavoritesService favoritesService;

  const CompactPlayerInfoLayout({
    super.key,
    required this.song,
    required this.heroTag,
    required this.playerService,
    required this.favoritesService,
  });

  @override
  State<CompactPlayerInfoLayout> createState() =>
      _CompactPlayerInfoLayoutState();
}

class _CompactPlayerInfoLayoutState extends State<CompactPlayerInfoLayout> {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Hero(
                tag: widget.heroTag,
                child: Container(
                  width: MediaQuery.sizeOf(context).height * 0.28,
                  height: MediaQuery.sizeOf(context).height * 0.28,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 24,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: widget.song.albumArt != null
                        ? CachedImageWidget(
                            imagePath: widget.song.albumArt!,
                            fit: BoxFit.cover,
                          )
                        : Container(
                            color: AppColors.glassBackgroundStrong,
                            child: const Icon(
                              LucideIcons.music,
                              size: 40,
                              color: AppColors.textTertiary,
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.song.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'ProductSans',
                        fontSize: context.responsiveText(18.0),
                        fontWeight: FontWeight.bold,
                        color: context.adaptiveTextPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'ProductSans',
                        fontSize: context.responsiveText(14.0),
                        color: context.adaptiveTextSecondary,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: context.adaptiveTextTertiary.withValues(
                              alpha: 0.1,
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            widget.song.fileType,
                            style: TextStyle(
                              fontFamily: 'ProductSans',
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: context.adaptiveTextSecondary,
                            ),
                          ),
                        ),
                        if (widget.song.resolution != null) ...[
                          const SizedBox(width: 6),
                          Text(
                            widget.song.resolution!,
                            style: TextStyle(
                              fontFamily: 'ProductSans',
                              fontSize: 10,
                              color: context.adaptiveTextTertiary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: widget.playerService.isShuffleNotifier,
                builder: (context, isShuffle, _) {
                  return IconButton(
                    onPressed: () => widget.playerService.toggleShuffle(),
                    icon: Icon(
                      LucideIcons.shuffle,
                      color: isShuffle
                          ? context.adaptiveAccent
                          : context.adaptiveTextTertiary,
                      size: 24,
                    ),
                  );
                },
              ),
              const SizedBox(width: 32),
              ValueListenableBuilder<LoopMode>(
                valueListenable: widget.playerService.loopModeNotifier,
                builder: (context, loopMode, _) {
                  IconData icon = LucideIcons.repeat;
                  Color color = context.adaptiveTextTertiary;
                  if (loopMode == LoopMode.all) {
                    color = context.adaptiveAccent;
                  }
                  if (loopMode == LoopMode.one) {
                    icon = LucideIcons.repeat1;
                    color = context.adaptiveAccent;
                  }
                  return IconButton(
                    onPressed: () => widget.playerService.toggleLoopMode(),
                    icon: Icon(icon, color: color, size: 24),
                  );
                },
              ),
              const SizedBox(width: 32),
              FutureBuilder<bool>(
                future: widget.favoritesService.isFavorite(widget.song.id),
                builder: (context, snapshot) {
                  final isFavorite = snapshot.data ?? false;
                  return IconButton(
                    onPressed: () async {
                      final newState = await widget.favoritesService
                          .toggleFavorite(widget.song.id);
                      setState(() {});
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              newState
                                  ? 'Added to favorites'
                                  : 'Removed from favorites',
                            ),
                            duration: const Duration(seconds: 1),
                          ),
                        );
                      }
                    },
                    icon: Icon(
                      isFavorite ? Icons.favorite : Icons.favorite_border,
                      color: isFavorite
                          ? Colors.red
                          : context.adaptiveTextTertiary,
                      size: 24,
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
