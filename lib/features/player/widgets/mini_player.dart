import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/utils/navigation_helper.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/player_service.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flick/widgets/uac2/uac2_player_status.dart';

class MiniPlayer extends ConsumerStatefulWidget {
  const MiniPlayer({super.key});

  @override
  ConsumerState<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends ConsumerState<MiniPlayer> {
  final PlayerService _playerService = PlayerService();

  Future<void> _openQueue(BuildContext context) async {
    await NavigationHelper.navigateToQueue(context);
  }

  Widget _buildQueueButton(BuildContext context, int queueCount) {
    final hasQueue = queueCount > 0;

    return GestureDetector(
      onTap: () => _openQueue(context),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: EdgeInsets.symmetric(
          horizontal: hasQueue ? 10 : 8,
          vertical: 8,
        ),
        decoration: BoxDecoration(
          color: hasQueue
              ? AppColors.accent.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: hasQueue
                ? AppColors.accent.withValues(alpha: 0.26)
                : AppColors.glassBorder.withValues(alpha: 0.14),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.listMusic,
              size: 17,
              color: hasQueue ? AppColors.accentLight : AppColors.textSecondary,
            ),
            if (hasQueue) ...[
              const SizedBox(width: 6),
              Text(
                '$queueCount',
                style: const TextStyle(
                  fontFamily: 'ProductSans',
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Use ValueListenableBuilder on currentSongNotifier so that the mini-player
    // appears immediately after restoreLastPlayed() runs on cold start — even
    // before the audio engine has been initialised and emitted a stream event.
    return ValueListenableBuilder<Song?>(
      valueListenable: _playerService.currentSongNotifier,
      builder: (context, song, _) {
        if (song == null) return const SizedBox.shrink();

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
              color: AppColors.glassBackgroundStrong,
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
                  // Progress bar — driven by positionNotifier + durationNotifier
                  ValueListenableBuilder<Duration>(
                    valueListenable: _playerService.positionNotifier,
                    builder: (context, position, _) {
                      return ValueListenableBuilder<Duration>(
                        valueListenable: _playerService.durationNotifier,
                        builder: (context, duration, _) {
                          if (duration.inMilliseconds <= 0) {
                            return const SizedBox.shrink();
                          }
                          return Align(
                            alignment: Alignment.bottomLeft,
                            child: FractionallySizedBox(
                              widthFactor: (position.inMilliseconds /
                                      duration.inMilliseconds)
                                  .clamp(0.0, 1.0),
                              child: Container(
                                height: 2,
                                color: AppColors.accent,
                              ),
                            ),
                          );
                        },
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
                            child: CachedImageWidget(
                              imagePath: song.albumArt,
                              audioSourcePath: song.filePath,
                              fit: BoxFit.cover,
                              useThumbnail: true,
                              thumbnailWidth: 128,
                              thumbnailHeight: 128,
                              placeholder: const Icon(
                                LucideIcons.music,
                                size: 24,
                                color: AppColors.textTertiary,
                              ),
                              errorWidget: const Icon(
                                LucideIcons.music,
                                size: 24,
                                color: AppColors.textTertiary,
                              ),
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
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    song.artist,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontFamily: 'ProductSans',
                                      fontSize: 13,
                                      color: AppColors.textTertiary,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Uac2PlayerStatus(
                                  compact: true,
                                  showDeviceName: false,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      // Controls
                      ValueListenableBuilder<List<Song>>(
                        valueListenable: _playerService.queueNotifier,
                        builder: (context, queue, _) {
                          return Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: _buildQueueButton(context, queue.length),
                          );
                        },
                      ),

                      // Play/Pause — driven by isPlayingNotifier for instant feedback
                      ValueListenableBuilder<bool>(
                        valueListenable: _playerService.isPlayingNotifier,
                        builder: (context, isPlaying, _) {
                          return IconButton(
                            onPressed: () =>
                                _playerService.togglePlayPause(),
                            icon: Icon(
                              isPlaying
                                  ? LucideIcons.pause
                                  : LucideIcons.play,
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
