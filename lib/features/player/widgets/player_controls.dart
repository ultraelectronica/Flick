import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/models/song.dart';
import 'package:flick/models/shuffle_mode.dart';
import 'package:flick/models/album_color_mode.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/utils/app_haptics.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/features/player/widgets/album_color_helpers.dart';
import 'package:flick/features/player/widgets/shuffle_mode_sheet.dart';
import 'package:flick/features/player/widgets/loop_mode_sheet.dart';

class PlayerControls extends StatelessWidget {
  final PlayerService playerService;
  final String Function(Duration) formatDuration;
  final Song? currentSong;
  final Future<void> Function() onPrevious;
  final Future<void> Function() onNext;
  final double timelineHorizontalPadding;
  final AlbumColorMode albumColorMode;
  final Color? albumColor;
  final bool showTimeLabels;

  const PlayerControls({super.key,
    required this.playerService,
    required this.formatDuration,
    required this.currentSong,
    required this.onPrevious,
    required this.onNext,
    this.timelineHorizontalPadding = 0,
    this.albumColorMode = AlbumColorMode.off,
    this.albumColor,
    this.showTimeLabels = true,
  });

  @override
  Widget build(BuildContext context) {
    final surfaceBlend = albumColorMode.surfaceBlend;
    final accentBlend = albumColorMode.accentBlend;
    final hasAlbumTint = albumColor != null && surfaceBlend > 0;

    final buttonSurface = hasAlbumTint
        ? albumSurface(albumColor!, surfaceBlend)
        : const Color(0xFF121212);
    final activeAccent = hasAlbumTint
        ? albumAccent(albumColor!, accentBlend)
        : AppColors.accent;

    return RepaintBoundary(
      child: ValueListenableBuilder<Duration>(
        valueListenable: playerService.positionNotifier,
        builder: (context, position, _) {
          return ValueListenableBuilder<Duration>(
            valueListenable: playerService.durationNotifier,
            builder: (context, engineDuration, _) {
              final duration = engineDuration.inMilliseconds > 0
                  ? engineDuration
                  : (currentSong?.duration ?? Duration.zero);

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSize(
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeInOut,
                    alignment: Alignment.bottomCenter,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                      opacity: showTimeLabels ? 1.0 : 0.0,
                      child: showTimeLabels
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                PlaybackTimeLabels(
                                  position: position,
                                  duration: duration,
                                  formatDuration: formatDuration,
                                  horizontalPadding:
                                      timelineHorizontalPadding,
                                ),
                                const SizedBox(height: 12),
                              ],
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Shuffle
                      ValueListenableBuilder<ShuffleMode>(
                        valueListenable: playerService.shuffleModeNotifier,
                        builder: (context, shuffleMode, _) {
                          final isActive = shuffleMode.isActive;
                          final icon = switch (shuffleMode) {
                            ShuffleMode.categories => LucideIcons.layers,
                            ShuffleMode.random => LucideIcons.dices,
                            _ => LucideIcons.shuffle,
                          };
                          return GestureDetector(
                            onTap: () {
                              AppHaptics.tap();
                              playerService.toggleShuffle();
                              final next =
                                  playerService.shuffleModeNotifier.value;
                              ScaffoldMessenger.of(context)
                                ..hideCurrentSnackBar()
                                ..showSnackBar(
                                  SnackBar(
                                    content: Text('Shuffle: ${next.label}'),
                                    behavior: SnackBarBehavior.floating,
                                    duration: const Duration(seconds: 1),
                                  ),
                                );
                            },
                            onLongPress: () {
                              AppHaptics.tap();
                              ShuffleModeSheet.show(context, playerService);
                            },
                            child: Container(
                              width: context.responsive(40.0, 44.0, 48.0),
                              height: context.responsive(40.0, 44.0, 48.0),
                              decoration: BoxDecoration(
                                color: isActive
                                    ? activeAccent.withValues(alpha: 0.25)
                                    : buttonSurface.withValues(alpha: 0.6),
                                shape: BoxShape.circle,
                                border: isActive
                                    ? Border.all(
                                        color: activeAccent.withValues(
                                          alpha: 0.6,
                                        ),
                                        width: 1.5,
                                      )
                                    : null,
                              ),
                              child: Icon(
                                icon,
                                size: context.responsive(18.0, 20.0, 22.0),
                                color: isActive
                                    ? activeAccent
                                    : Colors.white.withValues(alpha: 0.7),
                              ),
                            ),
                          );
                        },
                      ),
                      SizedBox(width: context.responsive(14.0, 18.0, 22.0)),
                      // Previous
                      Container(
                        width: context.responsive(40.0, 44.0, 48.0),
                        height: context.responsive(40.0, 44.0, 48.0),
                        decoration: BoxDecoration(
                          color: buttonSurface.withValues(alpha: 0.6),
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          onPressed: () {
                            AppHaptics.tap();
                            onPrevious();
                          },
                          iconSize: context.responsive(18.0, 20.0, 22.0),
                          padding: EdgeInsets.zero,
                          icon: Icon(LucideIcons.skipBack, color: Colors.white),
                        ),
                      ),
                      SizedBox(width: context.responsive(14.0, 18.0, 22.0)),
                      // Play/Pause
                      _PlayPauseButton(
                        playerService: playerService,
                        albumColorMode: albumColorMode,
                        albumColor: albumColor,
                      ),
                      SizedBox(width: context.responsive(14.0, 18.0, 22.0)),
                      // Next
                      Container(
                        width: context.responsive(40.0, 44.0, 48.0),
                        height: context.responsive(40.0, 44.0, 48.0),
                        decoration: BoxDecoration(
                          color: buttonSurface.withValues(alpha: 0.6),
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          onPressed: () {
                            AppHaptics.tap();
                            onNext();
                          },
                          iconSize: context.responsive(18.0, 20.0, 22.0),
                          padding: EdgeInsets.zero,
                          icon: Icon(
                            LucideIcons.skipForward,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      SizedBox(width: context.responsive(14.0, 18.0, 22.0)),
                      // Repeat/Loop
                      ValueListenableBuilder<LoopMode>(
                        valueListenable: playerService.loopModeNotifier,
                        builder: (context, loopMode, _) {
                          final icon = LoopModeSheet.iconFor(loopMode);
                          final isActive = loopMode != LoopMode.off;
                          final color = isActive
                              ? activeAccent
                              : Colors.white.withValues(alpha: 0.7);
                          return GestureDetector(
                            onTap: () {
                              AppHaptics.tap();
                              playerService.toggleLoopMode();
                              final next = playerService.loopModeNotifier.value;
                              ScaffoldMessenger.of(context)
                                ..hideCurrentSnackBar()
                                ..showSnackBar(
                                  SnackBar(
                                    content: Text('Repeat: ${next.label}'),
                                    behavior: SnackBarBehavior.floating,
                                    duration: const Duration(seconds: 1),
                                  ),
                                );
                            },
                            onLongPress: () {
                              AppHaptics.tap();
                              LoopModeSheet.show(context, playerService);
                            },
                            child: Container(
                              width: context.responsive(40.0, 44.0, 48.0),
                              height: context.responsive(40.0, 44.0, 48.0),
                              decoration: BoxDecoration(
                                color: buttonSurface.withValues(alpha: 0.6),
                                shape: BoxShape.circle,
                              ),
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  Icon(
                                    icon,
                                    size: context.responsive(18.0, 20.0, 22.0),
                                    color: color,
                                  ),
                                  if (loopMode == LoopMode.all)
                                    Positioned(
                                      bottom: 6,
                                      child: Container(
                                        width: 4,
                                        height: 4,
                                        decoration: BoxDecoration(
                                          color: activeAccent,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class PlaybackTimeLabels extends StatelessWidget {
  final Duration position;
  final Duration duration;
  final String Function(Duration) formatDuration;
  final double horizontalPadding;

  const PlaybackTimeLabels({super.key,
    required this.position,
    required this.duration,
    required this.formatDuration,
    this.horizontalPadding = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            formatDuration(position),
            style: const TextStyle(
              fontFamily: 'ProductSans',
              fontSize: 12,
              color: Colors.white,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            formatDuration(duration),
            style: const TextStyle(
              fontFamily: 'ProductSans',
              fontSize: 12,
              color: Colors.white,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// Extracted play/pause button to minimize rebuilds when only play state changes
class _PlayPauseButton extends StatelessWidget {
  final PlayerService playerService;
  final AlbumColorMode albumColorMode;
  final Color? albumColor;

  const _PlayPauseButton({
    required this.playerService,
    this.albumColorMode = AlbumColorMode.off,
    this.albumColor,
  });

  @override
  Widget build(BuildContext context) {
    final surfaceBlend = albumColorMode.surfaceBlend;
    final accentBlend = albumColorMode.accentBlend;
    final hasAlbumTint = albumColor != null && surfaceBlend > 0;

    final buttonSurface = hasAlbumTint
        ? albumSurface(albumColor!, surfaceBlend)
        : const Color(0xFF121212);
    final glowColor = hasAlbumTint
        ? albumAccent(albumColor!, accentBlend)
        : AppColors.accent;

    return RepaintBoundary(
      child: ValueListenableBuilder<bool>(
        valueListenable: playerService.isPlayingNotifier,
        builder: (context, isPlaying, _) {
          final buttonSize = context.responsive(58.0, 64.0, 68.0);
          final iconSize = context.responsive(26.0, 28.0, 30.0);

          return Container(
            width: buttonSize,
            height: buttonSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: buttonSurface.withValues(alpha: 0.6),
              boxShadow: [
                BoxShadow(
                  color: glowColor.withValues(alpha: 0.4),
                  blurRadius: context.responsive(14.0, 18.0, 22.0),
                  offset: Offset(0, context.responsive(5.0, 6.0, 7.0)),
                ),
              ],
            ),
            child: IconButton(
              onPressed: () {
                AppHaptics.tap();
                playerService.togglePlayPause();
              },
              iconSize: iconSize,
              padding: EdgeInsets.zero,
              icon: Icon(
                isPlaying ? LucideIcons.pause : LucideIcons.play,
                color: Colors.white,
              ),
            ),
          );
        },
      ),
    );
  }
}

