import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/favorites_service.dart';
import 'package:flick/features/player/widgets/waveform_seek_bar.dart';
import 'package:flick/features/player/widgets/ambient_background.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flick/widgets/navigation/flick_nav_bar.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';

class FullPlayerScreen extends StatefulWidget {
  final Object heroTag;
  const FullPlayerScreen({super.key, this.heroTag = 'album_art_hero'});

  @override
  State<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends State<FullPlayerScreen> {
  final PlayerService _playerService = PlayerService();
  final FavoritesService _favoritesService = FavoritesService();

  // Track drag offset for swipe-down to dismiss
  double _dragOffset = 0;

  // Throttled position for waveform updates (updates every 100ms instead of every frame)
  Duration _throttledPosition = Duration.zero;
  Timer? _positionThrottleTimer;

  @override
  void initState() {
    super.initState();
    // Initialize with current position
    _throttledPosition = _playerService.positionNotifier.value;
    // Set up throttled position updates for waveform (100ms interval)
    _positionThrottleTimer = Timer.periodic(const Duration(milliseconds: 100), (
      timer,
    ) {
      if (mounted) {
        final newPosition = _playerService.positionNotifier.value;
        // Only update if position actually changed
        if (_throttledPosition != newPosition) {
          _throttledPosition = newPosition;
          setState(() {});
        }
      }
    });
  }

  @override
  void dispose() {
    _positionThrottleTimer?.cancel();
    super.dispose();
  }

  // For nice time formatting (mm:ss)
  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  void _showSpeedBottomSheet(BuildContext context) {
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: AppColors.glassBackgroundStrong.withValues(alpha: 0.95),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: AppColors.glassBorder, width: 1),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  LucideIcons.gauge,
                  color: AppColors.accent,
                  size: 24,
                ),
                const SizedBox(width: 12),
                const Text(
                  'Playback Speed',
                  style: TextStyle(
                    fontFamily: 'ProductSans',
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            ValueListenableBuilder<double>(
              valueListenable: _playerService.playbackSpeedNotifier,
              builder: (context, currentSpeed, _) {
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: speeds.map((speed) {
                    final isSelected = speed == currentSpeed;
                    return GestureDetector(
                      onTap: () {
                        _playerService.setPlaybackSpeed(speed);
                        Navigator.pop(context);
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? AppColors.accent
                              : AppColors.glassBackground,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isSelected
                                ? AppColors.accent
                                : AppColors.glassBorder,
                            width: 1,
                          ),
                        ),
                        child: Text(
                          '${speed}x',
                          style: TextStyle(
                            fontFamily: 'ProductSans',
                            fontSize: 16,
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: isSelected
                                ? Colors.white
                                : AppColors.textPrimary,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  void _showSleepTimerBottomSheet(BuildContext context) {
    final timerOptions = [
      (const Duration(minutes: 15), '15 min'),
      (const Duration(minutes: 30), '30 min'),
      (const Duration(minutes: 45), '45 min'),
      (const Duration(hours: 1), '1 hour'),
      (const Duration(hours: 2), '2 hours'),
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: AppColors.glassBackgroundStrong.withValues(alpha: 0.95),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: AppColors.glassBorder, width: 1),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(
                      LucideIcons.moonStar,
                      color: AppColors.accent,
                      size: 24,
                    ),
                    const SizedBox(width: 12),
                    const Text(
                      'Sleep Timer',
                      style: TextStyle(
                        fontFamily: 'ProductSans',
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
                if (_playerService.isSleepTimerActive)
                  TextButton(
                    onPressed: () {
                      _playerService.cancelSleepTimer();
                      Navigator.pop(context);
                    },
                    child: const Text(
                      'Cancel Timer',
                      style: TextStyle(
                        fontFamily: 'ProductSans',
                        color: Colors.redAccent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<Duration?>(
              valueListenable: _playerService.sleepTimerRemainingNotifier,
              builder: (context, remaining, _) {
                if (remaining != null) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.accent.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppColors.accent.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            LucideIcons.timer,
                            color: AppColors.accent,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Stopping in ${_formatDuration(remaining)}',
                            style: const TextStyle(
                              fontFamily: 'ProductSans',
                              fontSize: 14,
                              color: AppColors.accent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: timerOptions.map((option) {
                return GestureDetector(
                  onTap: () {
                    _playerService.setSleepTimer(option.$1);
                    Navigator.pop(context);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.glassBackground,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppColors.glassBorder,
                        width: 1,
                      ),
                    ),
                    child: Text(
                      option.$2,
                      style: const TextStyle(
                        fontFamily: 'ProductSans',
                        fontSize: 16,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
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

          return GestureDetector(
            onVerticalDragUpdate: (details) {
              // Only track downward drag
              if (details.delta.dy > 0) {
                _dragOffset += details.delta.dy;
                setState(() {});
              }
            },
            onVerticalDragEnd: (details) {
              // If dragged down enough or with enough velocity, dismiss
              if (_dragOffset > 100 || details.primaryVelocity! > 500) {
                Navigator.of(context).pop();
              }
              // Reset drag offset
              _dragOffset = 0;
              setState(() {});
            },
            onHorizontalDragEnd: (details) {
              if (details.primaryVelocity! < -500) {
                // Swipe Left -> Next
                _playerService.next();
              } else if (details.primaryVelocity! > 500) {
                // Swipe Right -> Previous
                _playerService.previous();
              }
            },
            child: AnimatedContainer(
              duration: _dragOffset == 0
                  ? const Duration(milliseconds: 200)
                  : Duration.zero,
              curve: Curves.easeOut,
              transform: Matrix4.translationValues(0, _dragOffset * 0.5, 0),
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
                                icon: Icon(
                                  LucideIcons.chevronDown,
                                  color: context.adaptiveTextPrimary,
                                ),
                              ),
                              Text(
                                "Now Playing",
                                style: TextStyle(
                                  fontFamily: 'ProductSans',
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: context.adaptiveTextSecondary,
                                  letterSpacing: 1,
                                ),
                              ),
                              PopupMenuButton<String>(
                                icon: Icon(
                                  Icons.more_vert,
                                  color: context.adaptiveTextPrimary,
                                ),
                                color: AppColors.glassBackgroundStrong,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                itemBuilder: (context) => [
                                  PopupMenuItem(
                                    value: 'speed',
                                    child: ValueListenableBuilder<double>(
                                      valueListenable:
                                          _playerService.playbackSpeedNotifier,
                                      builder: (context, speed, _) {
                                        return Row(
                                          children: [
                                            const Icon(
                                              LucideIcons.gauge,
                                              color: AppColors.textPrimary,
                                              size: 20,
                                            ),
                                            const SizedBox(width: 12),
                                            Text(
                                              'Speed: ${speed}x',
                                              style: const TextStyle(
                                                fontFamily: 'ProductSans',
                                                color: AppColors.textPrimary,
                                              ),
                                            ),
                                          ],
                                        );
                                      },
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'timer',
                                    child: ValueListenableBuilder<Duration?>(
                                      valueListenable: _playerService
                                          .sleepTimerRemainingNotifier,
                                      builder: (context, remaining, _) {
                                        return Row(
                                          children: [
                                            Icon(
                                              LucideIcons.moonStar,
                                              color: remaining != null
                                                  ? AppColors.accent
                                                  : AppColors.textPrimary,
                                              size: 20,
                                            ),
                                            const SizedBox(width: 12),
                                            Text(
                                              remaining != null
                                                  ? 'Sleep: ${_formatDuration(remaining)}'
                                                  : 'Sleep Timer',
                                              style: TextStyle(
                                                fontFamily: 'ProductSans',
                                                color: remaining != null
                                                    ? AppColors.accent
                                                    : AppColors.textPrimary,
                                              ),
                                            ),
                                          ],
                                        );
                                      },
                                    ),
                                  ),
                                ],
                                onSelected: (value) {
                                  if (value == 'speed') {
                                    _showSpeedBottomSheet(context);
                                  } else if (value == 'timer') {
                                    _showSleepTimerBottomSheet(context);
                                  }
                                },
                              ),
                            ],
                          ),
                        ),

                        const Spacer(flex: 1),

                        // Hero Album Art
                        Hero(
                          tag: widget.heroTag,
                          child: Container(
                            width:
                                context.responsive(0.8, 0.85) *
                                MediaQuery.of(context).size.width,
                            height:
                                context.responsive(0.8, 0.85) *
                                MediaQuery.of(context).size.width,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(40),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.3),
                                  blurRadius: 32,
                                  offset: const Offset(0, 16),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(40),
                              child: song.albumArt != null
                                  ? CachedImageWidget(
                                      imagePath: song.albumArt!,
                                      fit: BoxFit.cover,
                                    )
                                  : Container(
                                      decoration: BoxDecoration(
                                        color: AppColors.glassBackgroundStrong,
                                        borderRadius: BorderRadius.circular(40),
                                      ),
                                      child: const Icon(
                                        LucideIcons.music,
                                        size: 80,
                                        color: AppColors.textTertiary,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 32),
                        // Title & Artist (centered)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Column(
                            children: [
                              Text(
                                song.title,
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: 'ProductSans',
                                  fontSize: context.responsiveText(
                                    AppConstants.fontSizeXxl,
                                  ),
                                  fontWeight: FontWeight.bold,
                                  color: context.adaptiveTextPrimary,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                song.artist,
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: 'ProductSans',
                                  fontSize: context.responsiveText(
                                    AppConstants.fontSizeLg,
                                  ),
                                  color: context.adaptiveTextSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 8),
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
                                color: context.adaptiveTextTertiary.withValues(
                                  alpha: 0.1,
                                ),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                song.fileType,
                                style: TextStyle(
                                  fontFamily: 'ProductSans',
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: context.adaptiveTextSecondary,
                                ),
                              ),
                            ),
                            if (song.resolution != null) ...[
                              const SizedBox(width: 8),
                              Text(
                                song.resolution!,
                                style: TextStyle(
                                  fontFamily: 'ProductSans',
                                  fontSize: 11,
                                  color: context.adaptiveTextTertiary,
                                ),
                              ),
                            ],
                          ],
                        ),

                        const SizedBox(height: 16),
                        // Control buttons row (Shuffle, Loop, Favorite)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // Shuffle
                            ValueListenableBuilder<bool>(
                              valueListenable: _playerService.isShuffleNotifier,
                              builder: (context, isShuffle, _) {
                                return IconButton(
                                  onPressed: () =>
                                      _playerService.toggleShuffle(),
                                  icon: Icon(
                                    LucideIcons.shuffle,
                                    color: isShuffle
                                        ? context.adaptiveAccent
                                        : context.adaptiveTextTertiary,
                                    size: context.responsiveIcon(
                                      AppConstants.iconSizeMd,
                                    ),
                                  ),
                                );
                              },
                            ),
                            const SizedBox(width: 16),
                            // Loop
                            ValueListenableBuilder<LoopMode>(
                              valueListenable: _playerService.loopModeNotifier,
                              builder: (context, loopMode, _) {
                                IconData icon;
                                Color color;
                                switch (loopMode) {
                                  case LoopMode.off:
                                    icon = LucideIcons.repeat;
                                    color = context.adaptiveTextTertiary;
                                    break;
                                  case LoopMode.all:
                                    icon = LucideIcons.repeat;
                                    color = context.adaptiveAccent;
                                    break;
                                  case LoopMode.one:
                                    icon = LucideIcons.repeat1;
                                    color = context.adaptiveAccent;
                                    break;
                                }
                                return IconButton(
                                  onPressed: () =>
                                      _playerService.toggleLoopMode(),
                                  icon: Icon(
                                    icon,
                                    color: color,
                                    size: context.responsiveIcon(
                                      AppConstants.iconSizeMd,
                                    ),
                                  ),
                                );
                              },
                            ),
                            const SizedBox(width: 16),
                            // Favorite
                            FutureBuilder<bool>(
                              future: _favoritesService.isFavorite(song.id),
                              builder: (context, snapshot) {
                                final isFavorite = snapshot.data ?? false;
                                return IconButton(
                                  onPressed: () async {
                                    final newState = await _favoritesService
                                        .toggleFavorite(song.id);
                                    setState(() {});
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
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
                                    isFavorite
                                        ? Icons.favorite
                                        : Icons.favorite_border,
                                    color: isFavorite
                                        ? Colors.red
                                        : context.adaptiveTextTertiary,
                                    size: context.responsiveIcon(
                                      AppConstants.iconSizeMd,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),

                        const Spacer(flex: 1),

                        // Scrolling Waveform & Controls
                        SizedBox(
                          height: 160,
                          child: Stack(
                            children: [
                              // Waveform Layer - extracted to separate widget
                              Positioned.fill(
                                child: _WaveformLayer(
                                  playerService: _playerService,
                                  throttledPosition: _throttledPosition,
                                ),
                              ),

                              // Controls Layer - extracted to separate widget
                              Center(
                                child: _PlayerControls(
                                  playerService: _playerService,
                                  formatDuration: _formatDuration,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 130),
                      ],
                    ),
                  ),

                  // Navigation Bar (without mini player)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: FlickNavBar(
                      currentIndex:
                          1, // Songs is always selected when in player
                      onTap: (index) {
                        // Pop the full player and pass the index to navigate to
                        Navigator.of(context).pop(index);
                      },
                      showMiniPlayer: false,
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

/// Extracted waveform layer widget to reduce nesting and improve performance
class _WaveformLayer extends StatelessWidget {
  final PlayerService playerService;
  final Duration throttledPosition;

  const _WaveformLayer({
    required this.playerService,
    required this.throttledPosition,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<Duration>(
        valueListenable: playerService.durationNotifier,
        builder: (context, duration, _) {
          if (duration.inMilliseconds == 0) {
            return const SizedBox();
          }

          final screenWidth = MediaQuery.of(context).size.width;
          final waveWidth = screenWidth * 4;
          final progress =
              throttledPosition.inMilliseconds / duration.inMilliseconds;
          // Center the playhead
          final offset = -(progress * waveWidth) + (screenWidth / 2);

          return ClipRect(
            child: OverflowBox(
              maxWidth: waveWidth,
              minWidth: waveWidth,
              alignment: Alignment.centerLeft,
              child: Transform.translate(
                offset: Offset(offset, 0),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: RepaintBoundary(
                    child: WaveformSeekBar(
                      barCount: 80,
                      position: throttledPosition,
                      duration: duration,
                      onChanged: (newPos) {
                        playerService.seek(newPos);
                      },
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Extracted player controls widget to reduce nesting and improve performance
class _PlayerControls extends StatelessWidget {
  final PlayerService playerService;
  final String Function(Duration) formatDuration;

  const _PlayerControls({
    required this.playerService,
    required this.formatDuration,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<Duration>(
        valueListenable: playerService.positionNotifier,
        builder: (context, position, _) {
          return ValueListenableBuilder<Duration>(
            valueListenable: playerService.durationNotifier,
            builder: (context, duration, _) {
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Current Time
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF121212).withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      formatDuration(position),
                      style: const TextStyle(
                        fontFamily: 'ProductSans',
                        fontSize: 12,
                        color: AppColors.textPrimary,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Previous
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF121212).withValues(alpha: 0.6),
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      onPressed: () => playerService.previous(),
                      iconSize: 24,
                      icon: Icon(
                        LucideIcons.skipBack,
                        color: context.adaptiveTextPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),
                  // Play/Pause - separate widget to minimize rebuilds
                  _PlayPauseButton(playerService: playerService),
                  const SizedBox(width: 24),
                  // Next
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF121212).withValues(alpha: 0.6),
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      onPressed: () => playerService.next(),
                      iconSize: 24,
                      icon: Icon(
                        LucideIcons.skipForward,
                        color: context.adaptiveTextPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Total Duration
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF121212).withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      formatDuration(duration),
                      style: const TextStyle(
                        fontFamily: 'ProductSans',
                        fontSize: 12,
                        color: AppColors.textPrimary,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
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

/// Extracted play/pause button to minimize rebuilds when only play state changes
class _PlayPauseButton extends StatelessWidget {
  final PlayerService playerService;

  const _PlayPauseButton({required this.playerService});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<bool>(
        valueListenable: playerService.isPlayingNotifier,
        builder: (context, isPlaying, _) {
          return Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF121212).withValues(alpha: 0.6),
              boxShadow: [
                BoxShadow(
                  color: AppColors.accent.withValues(alpha: 0.4),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: IconButton(
              onPressed: () => playerService.togglePlayPause(),
              iconSize: 32,
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
