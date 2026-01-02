import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/features/player/widgets/waveform_seek_bar.dart';
import 'package:flick/features/player/widgets/ambient_background.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:just_audio/just_audio.dart';

class FullPlayerScreen extends StatefulWidget {
  final Object heroTag;
  const FullPlayerScreen({super.key, this.heroTag = 'album_art_hero'});

  @override
  State<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends State<FullPlayerScreen> {
  final PlayerService _playerService = PlayerService();

  // For nice time formatting (mm:ss)
  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: ValueListenableBuilder<Song?>(
        valueListenable: _playerService.currentSongNotifier,
        builder: (context, song, _) {
          if (song == null) {
            // Should usually close the screen if song becomes null or error
            WidgetsBinding.instance.addPostFrameCallback((_) {
              Navigator.of(context).pop();
            });
            return const SizedBox.shrink();
          }

          return Dismissible(
            key: const Key('full_player_dismiss'),
            direction: DismissDirection.down,
            onDismissed: (_) {
              Navigator.of(context).pop();
            },
            child: GestureDetector(
              onHorizontalDragEnd: (details) {
                if (details.primaryVelocity! < -500) {
                  // Swipe Left -> Next
                  _playerService.next();
                } else if (details.primaryVelocity! > 500) {
                  // Swipe Right -> Previous
                  _playerService.previous();
                }
              },
              child: Stack(
                children: [
                  // Ambient background
                  AmbientBackground(song: song),

                  SafeArea(
                    child: Column(
                      children: [
                        // Top Bar
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              IconButton(
                                onPressed: () => Navigator.of(context).pop(),
                                icon: const Icon(
                                  LucideIcons.chevronDown,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              const Text(
                                "Now Playing",
                                style: TextStyle(
                                  fontFamily: 'ProductSans',
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textSecondary,
                                  letterSpacing: 1,
                                ),
                              ),
                              IconButton(
                                onPressed: () {}, // Options menu
                                icon: const Icon(
                                  Icons.more_vert,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),

                        const Spacer(),

                        // Hero Album Art
                        Hero(
                          tag: widget.heroTag,
                          child: Container(
                            width: MediaQuery.of(context).size.width * 0.85,
                            height: MediaQuery.of(context).size.width * 0.85,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(40),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.3),
                                  blurRadius: 32,
                                  offset: const Offset(0, 16),
                                ),
                              ],
                              image: song.albumArt != null
                                  ? DecorationImage(
                                      image: FileImage(File(song.albumArt!)),
                                      fit: BoxFit.cover,
                                    )
                                  : null,
                            ),
                            child: song.albumArt == null
                                ? Container(
                                    decoration: BoxDecoration(
                                      color: AppColors.glassBackgroundStrong,
                                      borderRadius: BorderRadius.circular(40),
                                    ),
                                    child: const Icon(
                                      LucideIcons.music,
                                      size: 80,
                                      color: AppColors.textTertiary,
                                    ),
                                  )
                                : null,
                          ),
                        ),
                        const SizedBox(height: 48),
                        // Metadata (Row with Shuffle/Loop)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              // Shuffle
                              ValueListenableBuilder<bool>(
                                valueListenable:
                                    _playerService.isShuffleNotifier,
                                builder: (context, isShuffle, _) {
                                  return IconButton(
                                    onPressed: () =>
                                        _playerService.toggleShuffle(),
                                    icon: Icon(
                                      LucideIcons.shuffle,
                                      color: isShuffle
                                          ? AppColors.accent
                                          : AppColors.textTertiary,
                                    ),
                                  );
                                },
                              ),

                              // Title & Artist
                              Expanded(
                                child: Column(
                                  children: [
                                    Text(
                                      song.title,
                                      textAlign: TextAlign.center,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontFamily: 'ProductSans',
                                        fontSize: 24,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.textPrimary,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      song.artist,
                                      textAlign: TextAlign.center,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontFamily: 'ProductSans',
                                        fontSize: 16,
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // Loop
                              ValueListenableBuilder<LoopMode>(
                                valueListenable:
                                    _playerService.loopModeNotifier,
                                builder: (context, loopMode, _) {
                                  IconData icon;
                                  Color color;
                                  switch (loopMode) {
                                    case LoopMode.off:
                                      icon = LucideIcons.repeat;
                                      color = AppColors.textTertiary;
                                      break;
                                    case LoopMode.all:
                                      icon = LucideIcons.repeat;
                                      color = AppColors.accent;
                                      break;
                                    case LoopMode.one:
                                      icon = LucideIcons.repeat1;
                                      color = AppColors.accent;
                                      break;
                                  }
                                  return IconButton(
                                    onPressed: () =>
                                        _playerService.toggleLoopMode(),
                                    icon: Icon(icon, color: color),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 6),
                        // File Info
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.textTertiary.withValues(
                                  alpha: 0.1,
                                ),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                song.fileType,
                                style: const TextStyle(
                                  fontFamily: 'ProductSans',
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ),
                            if (song.resolution != null) ...[
                              const SizedBox(width: 8),
                              Text(
                                song.resolution!,
                                style: const TextStyle(
                                  fontFamily: 'ProductSans',
                                  fontSize: 11,
                                  color: AppColors.textTertiary,
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 12),

                        const Spacer(),

                        // Scrolling Waveform & Controls
                        SizedBox(
                          height: 160,
                          child: Stack(
                            children: [
                              // Waveform Layer
                              Positioned.fill(
                                child: ValueListenableBuilder<Duration>(
                                  valueListenable:
                                      _playerService.positionNotifier,
                                  builder: (context, position, _) {
                                    return ValueListenableBuilder<Duration>(
                                      valueListenable:
                                          _playerService.durationNotifier,
                                      builder: (context, duration, _) {
                                        if (duration.inMilliseconds == 0) {
                                          return const SizedBox();
                                        }

                                        final screenWidth = MediaQuery.of(
                                          context,
                                        ).size.width;
                                        final waveWidth = screenWidth * 4;
                                        final progress =
                                            position.inMilliseconds /
                                            duration.inMilliseconds;
                                        // Center the playhead
                                        final offset =
                                            -(progress * waveWidth) +
                                            (screenWidth / 2);

                                        return ClipRect(
                                          child: OverflowBox(
                                            maxWidth: waveWidth,
                                            minWidth: waveWidth,
                                            alignment: Alignment.centerLeft,
                                            child: Transform.translate(
                                              offset: Offset(offset, 0),
                                              child: Padding(
                                                padding: const EdgeInsets.symmetric(
                                                  vertical: 10,
                                                ), // Padding for controls space
                                                child: WaveformSeekBar(
                                                  barCount: 300,
                                                  position: position,
                                                  duration: duration,
                                                  onChanged: (newPos) {
                                                    // Seeking on a scrolling waveform is tricky visually
                                                    // Standard seek might feel weird if it jumps
                                                    _playerService.seek(newPos);
                                                  },
                                                ),
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    );
                                  },
                                ),
                              ),

                              // Controls Layer (Overlay) including Time Labels
                              Center(
                                child: ValueListenableBuilder<Duration>(
                                  valueListenable:
                                      _playerService.positionNotifier,
                                  builder: (context, position, _) {
                                    return ValueListenableBuilder<Duration>(
                                      valueListenable:
                                          _playerService.durationNotifier,
                                      builder: (context, duration, _) {
                                        return Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            // Current Time
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 12,
                                                    vertical: 8,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: const Color(
                                                  0xFF121212,
                                                ).withValues(alpha: 0.6),
                                                borderRadius:
                                                    BorderRadius.circular(20),
                                              ),
                                              child: Text(
                                                _formatDuration(position),
                                                style: const TextStyle(
                                                  fontFamily: 'ProductSans',
                                                  fontSize: 12,
                                                  color: AppColors.textPrimary,
                                                  fontFeatures: [
                                                    FontFeature.tabularFigures(),
                                                  ],
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 16),
                                            // Previous
                                            Container(
                                              decoration: BoxDecoration(
                                                color: const Color(
                                                  0xFF121212,
                                                ).withValues(alpha: 0.6),
                                                shape: BoxShape.circle,
                                              ),
                                              child: IconButton(
                                                onPressed: () =>
                                                    _playerService.previous(),
                                                iconSize: 24,
                                                icon: const Icon(
                                                  LucideIcons.skipBack,
                                                  color: AppColors.textPrimary,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 24),
                                            // Play/Pause
                                            ValueListenableBuilder<bool>(
                                              valueListenable: _playerService
                                                  .isPlayingNotifier,
                                              builder: (context, isPlaying, _) {
                                                return Container(
                                                  width: 72,
                                                  height: 72,
                                                  decoration: BoxDecoration(
                                                    shape: BoxShape.circle,
                                                    color: AppColors.accent,
                                                    boxShadow: [
                                                      BoxShadow(
                                                        color: AppColors.accent
                                                            .withValues(
                                                              alpha: 0.4,
                                                            ),
                                                        blurRadius: 24,
                                                        offset: const Offset(
                                                          0,
                                                          8,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  child: IconButton(
                                                    onPressed: () =>
                                                        _playerService
                                                            .togglePlayPause(),
                                                    iconSize: 32,
                                                    icon: Icon(
                                                      isPlaying
                                                          ? LucideIcons.pause
                                                          : LucideIcons.play,
                                                      color: Colors.white,
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                            const SizedBox(width: 24),
                                            // Next
                                            Container(
                                              decoration: BoxDecoration(
                                                color: const Color(
                                                  0xFF121212,
                                                ).withValues(alpha: 0.6),
                                                shape: BoxShape.circle,
                                              ),
                                              child: IconButton(
                                                onPressed: () =>
                                                    _playerService.next(),
                                                iconSize: 24,
                                                icon: const Icon(
                                                  LucideIcons.skipForward,
                                                  color: AppColors.textPrimary,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 16),
                                            // Total Duration
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 12,
                                                    vertical: 8,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: const Color(
                                                  0xFF121212,
                                                ).withValues(alpha: 0.6),
                                                borderRadius:
                                                    BorderRadius.circular(20),
                                              ),
                                              child: Text(
                                                _formatDuration(duration),
                                                style: const TextStyle(
                                                  fontFamily: 'ProductSans',
                                                  fontSize: 12,
                                                  color: AppColors.textPrimary,
                                                  fontFeatures: [
                                                    FontFeature.tabularFigures(),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ],
                                        );
                                      },
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 32),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
