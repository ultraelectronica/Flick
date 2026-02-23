import 'package:flutter/material.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/utils/navigation_helper.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/player_service.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';

class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  final PlayerService _playerService = PlayerService();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Song?>(
      valueListenable: _playerService.currentSongNotifier,
      builder: (context, song, child) {
        if (song == null) {
          return const SizedBox.shrink();
        }

        return GestureDetector(
          onTap: () {
            NavigationHelper.navigateToFullPlayer(
              context,
              heroTag: 'song_art_${song.id}',
            );
          },
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            height: 64,
            decoration: BoxDecoration(
              color: AppColors.glassBackgroundStrong, // Darker glass
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: AppColors.glassBorder.withValues(alpha: 0.1),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                children: [
                  // Progress Bar at bottom (optional, or background fill?)
                  // Let's keep it simple for now, maybe add a thin line at bottom later.
                  ValueListenableBuilder<Duration>(
                    valueListenable: _playerService.positionNotifier,
                    builder: (context, position, _) {
                      final duration = _playerService.durationNotifier.value;
                      if (duration.inMilliseconds == 0) {
                        return const SizedBox.shrink();
                      }
                      final progress =
                          position.inMilliseconds / duration.inMilliseconds;

                      return Align(
                        alignment: Alignment.bottomLeft,
                        child: FractionallySizedBox(
                          widthFactor: progress.clamp(0.0, 1.0),
                          child: Container(height: 2, color: AppColors.accent),
                        ),
                      );
                    },
                  ),

                  Row(
                    children: [
                      // Album Art
                      Hero(
                        tag: 'mini_player_art',
                        child: Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(16),
                              bottomLeft: Radius.circular(16),
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(16),
                              bottomLeft: Radius.circular(16),
                            ),
                            child: song.albumArt != null
                                ? CachedImageWidget(
                                    imagePath: song.albumArt!,
                                    fit: BoxFit.cover,
                                    useThumbnail: true,
                                    thumbnailWidth: 128,
                                    thumbnailHeight: 128,
                                  )
                                : const Icon(
                                    LucideIcons.music,
                                    size: 24,
                                    color: AppColors.textTertiary,
                                  ),
                          ),
                        ),
                      ),

                      const SizedBox(width: 12),

                      // Song Info
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              song.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'ProductSans',
                                fontWeight: FontWeight.w600,
                                fontSize: 15,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              song.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'ProductSans',
                                fontSize: 13,
                                color: AppColors.textTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Controls
                      ValueListenableBuilder<bool>(
                        valueListenable: _playerService.isPlayingNotifier,
                        builder: (context, isPlaying, _) {
                          return IconButton(
                            onPressed: () => _playerService.togglePlayPause(),
                            icon: Icon(
                              isPlaying ? LucideIcons.pause : LucideIcons.play,
                              color: AppColors.textPrimary,
                            ),
                          );
                        },
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
