import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/favorites_service.dart';
import 'package:flick/providers/playlist_provider.dart';
import 'package:flick/features/player/widgets/waveform_seek_bar.dart';
import 'package:flick/features/player/widgets/ambient_background.dart';
import 'package:flick/features/player/widgets/compact_player_info_layout.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flick/widgets/common/display_mode_wrapper.dart';
import 'package:flick/widgets/uac2/uac2_player_status.dart';
import 'package:flick/widgets/uac2/uac2_error_notification.dart';

class FullPlayerScreen extends StatefulWidget {
  final Object heroTag;
  const FullPlayerScreen({super.key, this.heroTag = 'album_art_hero'});

  @override
  State<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends State<FullPlayerScreen>
    with TickerProviderStateMixin {
  final PlayerService _playerService = PlayerService();
  final FavoritesService _favoritesService = FavoritesService();

  // Animation controller for drag offset (replaces setState)
  late AnimationController _dragController;

  // Track current drag offset (updated directly, no setState)
  double _dragOffset = 0.0;

  // Last drag update time for throttling
  DateTime _lastDragUpdate = DateTime.now();

  // Throttled position for waveform updates (updates every 50ms for smooth animation)
  Duration _throttledPosition = Duration.zero;
  Timer? _positionThrottleTimer;

  @override
  void initState() {
    super.initState();

    // Initialize drag animation controller for smooth return animation
    _dragController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      lowerBound: 0.0,
      upperBound: 1000.0, // Max drag distance
    );
    _dragController.value = 0.0;

    // Initialize with current position
    _throttledPosition = _playerService.positionNotifier.value;
    // Set up throttled position updates for waveform (50ms interval for smooth animation)
    _positionThrottleTimer = Timer.periodic(const Duration(milliseconds: 50), (
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
    _dragController.dispose();
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

  void _showAddToPlaylistDialog(BuildContext context, Song song) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  LucideIcons.listPlus,
                  color: AppColors.accent,
                  size: 24,
                ),
                const SizedBox(width: 12),
                Text(
                  'Add to Playlist',
                  style: TextStyle(
                    fontFamily: 'ProductSans',
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: context.adaptiveTextPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Consumer(
              builder: (context, ref, _) {
                final playlistsAsync = ref.watch(playlistsProvider);
                return playlistsAsync.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Text(
                    'Error loading playlists',
                    style: TextStyle(color: context.adaptiveTextTertiary),
                  ),
                  data: (state) {
                    if (state.playlists.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text(
                            'No playlists yet.\nCreate one in the Playlists tab.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: context.adaptiveTextTertiary,
                              fontFamily: 'ProductSans',
                            ),
                          ),
                        ),
                      );
                    }
                    return ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(context).size.height * 0.4,
                      ),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: state.playlists.length,
                        itemBuilder: (context, index) {
                          final playlist = state.playlists[index];
                          final isAlreadyAdded = playlist.songIds.contains(
                            song.id,
                          );
                          return ListTile(
                            leading: Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: AppColors.surfaceLight,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                LucideIcons.music,
                                color: context.adaptiveTextSecondary,
                              ),
                            ),
                            title: Text(
                              playlist.name,
                              style: TextStyle(
                                color: context.adaptiveTextPrimary,
                                fontFamily: 'ProductSans',
                              ),
                            ),
                            subtitle: Text(
                              '${playlist.songIds.length} songs',
                              style: TextStyle(
                                color: context.adaptiveTextTertiary,
                                fontFamily: 'ProductSans',
                              ),
                            ),
                            trailing: isAlreadyAdded
                                ? Icon(
                                    LucideIcons.check,
                                    color: AppColors.accent,
                                  )
                                : null,
                            onTap: isAlreadyAdded
                                ? null
                                : () async {
                                    await ref
                                        .read(playlistsProvider.notifier)
                                        .addSongToPlaylist(
                                          playlist.id,
                                          song.id,
                                        );
                                    if (context.mounted) {
                                      Navigator.pop(context);
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            'Added to "${playlist.name}"',
                                          ),
                                        ),
                                      );
                                    }
                                  },
                          );
                        },
                      ),
                    );
                  },
                );
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DisplayModeWrapper(
      child: Scaffold(
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
              onVerticalDragStart: (_) {
                _dragController.stop();
              },
              onVerticalDragUpdate: (details) {
                // Only track downward drag
                if (details.delta.dy > 0) {
                  // Throttle updates to every 16ms (~60fps) to avoid excessive updates
                  final now = DateTime.now();
                  if (now.difference(_lastDragUpdate).inMilliseconds < 16) {
                    return;
                  }
                  _lastDragUpdate = now;

                  // Update drag offset directly (no setState)
                  _dragOffset = (_dragOffset + details.delta.dy).clamp(
                    0.0,
                    1000.0,
                  );
                  // Update controller value for AnimatedBuilder
                  _dragController.value = _dragOffset;
                }
              },
              onVerticalDragEnd: (details) {
                // If dragged down enough or with enough velocity, dismiss
                if (_dragOffset > 100 || details.primaryVelocity! > 500) {
                  Navigator.of(context).pop();
                  return;
                }

                // Animate back to 0
                _dragOffset = 0.0;
                _dragController.animateTo(0.0);
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
              child: AnimatedBuilder(
                animation: _dragController,
                builder: (context, child) {
                  // Use Transform.translate during drag (lightweight)
                  // Only use animation when releasing
                  final offset = _dragController.value * 0.5;
                  return Transform.translate(
                    offset: Offset(0, offset),
                    child: child!,
                  );
                },
                child: Stack(
                  children: [
                    // Ambient background - wrapped in RepaintBoundary
                    RepaintBoundary(child: AmbientBackground(song: song)),

                    SafeArea(
                      child: Column(
                        children: [
                          const Uac2ErrorNotification(),
                          // Top Bar
                          Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: context.responsive(8.0, 12.0, 16.0),
                              vertical: context.responsive(4.0, 6.0, 8.0),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                IconButton(
                                  onPressed: () => Navigator.of(context).pop(),
                                  padding: EdgeInsets.all(context.responsive(8.0, 10.0, 12.0)),
                                  constraints: const BoxConstraints(),
                                  icon: Icon(
                                    LucideIcons.chevronDown,
                                    color: context.adaptiveTextPrimary,
                                    size: context.responsive(20.0, 22.0, 24.0),
                                  ),
                                ),
                                Text(
                                  "Now Playing",
                                  style: TextStyle(
                                    fontFamily: 'ProductSans',
                                    fontSize: context.responsive(12.0, 13.0, 14.0),
                                    fontWeight: FontWeight.w600,
                                    color: context.adaptiveTextSecondary,
                                    letterSpacing: 0.8,
                                  ),
                                ),
                                PopupMenuButton<String>(
                                  padding: EdgeInsets.all(context.responsive(8.0, 10.0, 12.0)),
                                  icon: Icon(
                                    Icons.more_vert,
                                    color: context.adaptiveTextPrimary,
                                    size: context.responsive(20.0, 22.0, 24.0),
                                  ),
                                  color: AppColors.surface,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  itemBuilder: (context) => [
                                    PopupMenuItem(
                                      value: 'add_to_playlist',
                                      child: Row(
                                        children: [
                                          const Icon(
                                            LucideIcons.listPlus,
                                            color: AppColors.textPrimary,
                                            size: 20,
                                          ),
                                          const SizedBox(width: 12),
                                          Text(
                                            'Add to Playlist',
                                            style: TextStyle(
                                              fontFamily: 'ProductSans',
                                              color:
                                                  context.adaptiveTextPrimary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    PopupMenuItem(
                                      value: 'speed',
                                      child: ValueListenableBuilder<double>(
                                        valueListenable: _playerService
                                            .playbackSpeedNotifier,
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
                                    if (value == 'add_to_playlist') {
                                      _showAddToPlaylistDialog(context, song);
                                    } else if (value == 'speed') {
                                      _showSpeedBottomSheet(context);
                                    } else if (value == 'timer') {
                                      _showSleepTimerBottomSheet(context);
                                    }
                                  },
                                ),
                              ],
                            ),
                          ),

                          Expanded(
                            child: Builder(
                              builder: (context) {
                                final mediaSize = MediaQuery.sizeOf(context);
                                // More adaptive compact height threshold
                                final isCompactHeight = mediaSize.height <= 650 || 
                                    (context.isCompact && mediaSize.height <= 700);

                                if (isCompactHeight) {
                                  return CompactPlayerInfoLayout(
                                    song: song,
                                    heroTag: widget.heroTag,
                                    playerService: _playerService,
                                    favoritesService: _favoritesService,
                                  );
                                }

                                return Column(
                                  children: [
                                    const SizedBox(height: 30),
                                    Hero(
                                      tag: widget.heroTag,
                                      child: Builder(
                                        builder: (context) {
                                          final screenWidth = MediaQuery.sizeOf(
                                            context,
                                          ).width;
                                          final screenHeight =
                                              MediaQuery.sizeOf(context).height;
                                          
                                          // Better responsive sizing for album art with safer constraints
                                          final double size;
                                          if (context.isCompact) {
                                            // Compact phones: smaller art, more space for controls
                                            size = (screenWidth * 0.60).clamp(160.0, screenHeight * 0.25);
                                          } else if (screenHeight < 700) {
                                            // Short screens: prioritize controls
                                            size = (screenWidth * 0.65).clamp(180.0, screenHeight * 0.28);
                                          } else {
                                            // Normal screens: larger art
                                            final maxSize = screenHeight * 0.36;
                                            size = (context.responsive(0.70, 0.75, 0.80) *
                                                    screenWidth)
                                                .clamp(200.0, maxSize);
                                          }

                                          final borderRadius = context.responsive(20.0, 28.0, 36.0);

                                          return Container(
                                            width: size,
                                            height: size,
                                            decoration: BoxDecoration(
                                              borderRadius:
                                                  BorderRadius.circular(borderRadius),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: Colors.black
                                                      .withValues(alpha: 0.3),
                                                  blurRadius: context.responsive(16.0, 24.0, 28.0),
                                                  offset: Offset(0, context.responsive(8.0, 12.0, 14.0)),
                                                ),
                                              ],
                                            ),
                                            child: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(borderRadius),
                                              child: song.albumArt != null
                                                  ? CachedImageWidget(
                                                      imagePath: song.albumArt!,
                                                      fit: BoxFit.cover,
                                                    )
                                                  : Container(
                                                      decoration: BoxDecoration(
                                                        color: AppColors
                                                            .glassBackgroundStrong,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              borderRadius,
                                                            ),
                                                      ),
                                                      child: Icon(
                                                        LucideIcons.music,
                                                        size: context.responsive(50.0, 60.0, 70.0),
                                                        color: AppColors
                                                            .textTertiary,
                                                      ),
                                                    ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                    SizedBox(
                                      height: context.responsive(20.0, 24.0, 28.0),
                                    ),
                                    Padding(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: context.responsive(12.0, 16.0, 20.0),
                                      ),
                                      child: AnimatedSwitcher(
                                        duration: const Duration(
                                          milliseconds: 300,
                                        ),
                                        transitionBuilder:
                                            (
                                              Widget child,
                                              Animation<double> animation,
                                            ) {
                                              return SlideTransition(
                                                position:
                                                    Tween<Offset>(
                                                      begin: const Offset(
                                                        1.0,
                                                        0.0,
                                                      ),
                                                      end: Offset.zero,
                                                    ).animate(
                                                      CurvedAnimation(
                                                        parent: animation,
                                                        curve: Curves.easeInOut,
                                                      ),
                                                    ),
                                                child: FadeTransition(
                                                  opacity: animation,
                                                  child: child,
                                                ),
                                              );
                                            },
                                        child: Column(
                                          key: ValueKey(song.id),
                                          children: [
                                            Text(
                                              song.title,
                                              textAlign: TextAlign.center,
                                              maxLines: context.isCompact ? 1 : 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontFamily: 'ProductSans',
                                                fontSize: context
                                                    .responsiveText(
                                                      context.responsive(18.0, 22.0, 26.0),
                                                    ),
                                                fontWeight: FontWeight.bold,
                                                color:
                                                    context.adaptiveTextPrimary,
                                              ),
                                            ),
                                            SizedBox(height: context.responsive(3.0, 5.0, 6.0)),
                                            Text(
                                              song.artist,
                                              textAlign: TextAlign.center,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontFamily: 'ProductSans',
                                                fontSize: context
                                                    .responsiveText(
                                                      context.responsive(13.0, 15.0, 17.0),
                                                    ),
                                                color: context
                                                    .adaptiveTextSecondary,
                                              ),
                                            ),
                                            SizedBox(height: context.responsive(6.0, 8.0, 8.0)),
                                            const Uac2PlayerStatus(
                                              compact: true,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    SizedBox(height: context.responsive(3.0, 5.0, 4.0)),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Container(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: context.responsive(4.0, 5.0, 6.0),
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: context.adaptiveTextTertiary
                                                .withValues(alpha: 0.1),
                                            borderRadius: BorderRadius.circular(
                                              3,
                                            ),
                                          ),
                                          child: Text(
                                            song.fileType,
                                            style: TextStyle(
                                              fontFamily: 'ProductSans',
                                              fontSize: context.responsive(9.0, 10.0, 11.0),
                                              fontWeight: FontWeight.w600,
                                              color:
                                                  context.adaptiveTextSecondary,
                                            ),
                                          ),
                                        ),
                                        if (song.resolution != null) ...[
                                          SizedBox(width: context.responsive(5.0, 6.0, 7.0)),
                                          Text(
                                            song.resolution!,
                                            style: TextStyle(
                                              fontFamily: 'ProductSans',
                                              fontSize: context.responsive(9.0, 10.0, 11.0),
                                              color:
                                                  context.adaptiveTextTertiary,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    SizedBox(height: context.responsive(6.0, 10.0, 8.0)),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        ValueListenableBuilder<bool>(
                                          valueListenable:
                                              _playerService.isShuffleNotifier,
                                          builder: (context, isShuffle, _) {
                                            return IconButton(
                                              onPressed: () => _playerService
                                                  .toggleShuffle(),
                                              padding: EdgeInsets.all(context.responsive(6.0, 8.0, 10.0)),
                                              constraints: const BoxConstraints(),
                                              icon: Icon(
                                                LucideIcons.shuffle,
                                                color: isShuffle
                                                    ? context.adaptiveAccent
                                                    : context
                                                          .adaptiveTextTertiary,
                                                size: context.responsiveIcon(
                                                  context.responsive(18.0, 20.0, 22.0),
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                        SizedBox(width: context.responsive(8.0, 12.0, 14.0)),
                                        ValueListenableBuilder<LoopMode>(
                                          valueListenable:
                                              _playerService.loopModeNotifier,
                                          builder: (context, loopMode, _) {
                                            IconData icon = LucideIcons.repeat;
                                            Color color =
                                                context.adaptiveTextTertiary;
                                            if (loopMode == LoopMode.all) {
                                              color = context.adaptiveAccent;
                                            }
                                            if (loopMode == LoopMode.one) {
                                              icon = LucideIcons.repeat1;
                                              color = context.adaptiveAccent;
                                            }
                                            return IconButton(
                                              onPressed: () => _playerService
                                                  .toggleLoopMode(),
                                              padding: EdgeInsets.all(context.responsive(6.0, 8.0, 10.0)),
                                              constraints: const BoxConstraints(),
                                              icon: Icon(
                                                icon,
                                                color: color,
                                                size: context.responsiveIcon(
                                                  context.responsive(18.0, 20.0, 22.0),
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                        SizedBox(width: context.responsive(8.0, 12.0, 14.0)),
                                        FutureBuilder<bool>(
                                          future: _favoritesService.isFavorite(
                                            song.id,
                                          ),
                                          builder: (context, snapshot) {
                                            final isFavorite =
                                                snapshot.data ?? false;
                                            return IconButton(
                                              onPressed: () async {
                                                final newState =
                                                    await _favoritesService
                                                        .toggleFavorite(
                                                          song.id,
                                                        );
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
                                                      duration: const Duration(
                                                        seconds: 1,
                                                      ),
                                                    ),
                                                  );
                                                }
                                              },
                                              padding: EdgeInsets.all(context.responsive(6.0, 8.0, 10.0)),
                                              constraints: const BoxConstraints(),
                                              icon: Icon(
                                                isFavorite
                                                    ? Icons.favorite
                                                    : Icons.favorite_border,
                                                color: isFavorite
                                                    ? Colors.red
                                                    : context
                                                          .adaptiveTextTertiary,
                                                size: context.responsiveIcon(
                                                  context.responsive(18.0, 20.0, 22.0),
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      ],
                                    ),
                                    SizedBox(height: context.responsive(2.0, 3.0, 0.0)),
                                  ],
                                );
                              },
                            ),
                          ),

                          // Waveform & Controls
                          Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: context.responsive(12.0, 16.0, 20.0),
                            ),
                            child: Column(
                              children: [
                                _WaveformLayer(
                                  playerService: _playerService,
                                  throttledPosition: _throttledPosition,
                                  currentSong: song,
                                ),
                                SizedBox(height: context.responsive(2.0, 3.0, 4.0)),
                                _PlayerControls(
                                  playerService: _playerService,
                                  formatDuration: _formatDuration,
                                  currentSong: song,
                                ),
                              ],
                            ),
                          ),
                          SizedBox(height: context.responsive(8.0, 12.0, 12.0)),
                          // Bottom Directory Info
                          if (song.filePath != null)
                            Builder(
                              builder: (context) {
                                String dirText = '';
                                final filePath = song.filePath!;
                                final parts = filePath.split(RegExp(r'[/\\]'));
                                if (parts.length > 1) {
                                  parts.removeLast(); // remove the file name
                                  final startIndex = parts.length > 2
                                      ? parts.length - 2
                                      : 0;
                                  final folders = parts.sublist(startIndex);
                                  dirText = folders.join('/');
                                }
                                if (dirText.isEmpty) {
                                  return const SizedBox.shrink();
                                }
                                return Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: context.responsive(12.0, 16.0, 20.0),
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        LucideIcons.folder,
                                        size: context.responsive(11.0, 12.0, 13.0),
                                        color: context.adaptiveTextPrimary,
                                      ),
                                      SizedBox(width: context.responsive(4.0, 5.0, 6.0)),
                                      Flexible(
                                        child: Text(
                                          dirText,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontFamily: 'ProductSans',
                                            fontSize: context.responsive(10.0, 11.0, 12.0),
                                            color: context.adaptiveTextPrimary,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          SizedBox(height: context.responsive(8.0, 12.0, 16.0)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Extracted waveform layer widget to reduce nesting and improve performance
/// Uses TweenAnimationBuilder for smooth position interpolation between updates
class _WaveformLayer extends StatelessWidget {
  final PlayerService playerService;
  final Duration throttledPosition;
  final Song? currentSong;

  const _WaveformLayer({
    required this.playerService,
    required this.throttledPosition,
    required this.currentSong,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Duration>(
      valueListenable: playerService.durationNotifier,
      builder: (context, engineDuration, _) {
        // Use engine duration if available, otherwise fallback to song duration
        final duration = engineDuration.inMilliseconds > 0
            ? engineDuration
            : (currentSong?.duration ?? Duration.zero);

        if (duration.inMilliseconds == 0) {
          return const SizedBox();
        }

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: RepaintBoundary(
            child: WaveformSeekBar(
              barCount: 60,
              position: throttledPosition,
              duration: duration,
              onChanged: (newPos) {
                playerService.seek(newPos);
              },
            ),
          ),
        );
      },
    );
  }
}

/// Extracted player controls widget to reduce nesting and improve performance
class _PlayerControls extends StatelessWidget {
  final PlayerService playerService;
  final String Function(Duration) formatDuration;
  final Song? currentSong;

  const _PlayerControls({
    required this.playerService,
    required this.formatDuration,
    required this.currentSong,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<Duration>(
        valueListenable: playerService.positionNotifier,
        builder: (context, position, _) {
          return ValueListenableBuilder<Duration>(
            valueListenable: playerService.durationNotifier,
            builder: (context, engineDuration, _) {
              // Use engine duration if available, otherwise fallback to song duration
              final duration = engineDuration.inMilliseconds > 0
                  ? engineDuration
                  : (currentSong?.duration ?? Duration.zero);

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        formatDuration(position),
                        style: const TextStyle(
                          fontFamily: 'ProductSans',
                          fontSize: 12,
                          color: AppColors.textPrimary,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      Text(
                        formatDuration(duration),
                        style: const TextStyle(
                          fontFamily: 'ProductSans',
                          fontSize: 12,
                          color: AppColors.textPrimary,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Previous
                      Container(
                        width: context.responsive(40.0, 44.0, 48.0),
                        height: context.responsive(40.0, 44.0, 48.0),
                        decoration: BoxDecoration(
                          color: const Color(0xFF121212).withValues(alpha: 0.6),
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          onPressed: () => playerService.previous(),
                          iconSize: context.responsive(18.0, 20.0, 22.0),
                          padding: EdgeInsets.zero,
                          icon: Icon(
                            LucideIcons.skipBack,
                            color: context.adaptiveTextPrimary,
                          ),
                        ),
                      ),
                      SizedBox(width: context.responsive(14.0, 18.0, 22.0)),
                      // Play/Pause - separate widget to minimize rebuilds
                      _PlayPauseButton(playerService: playerService),
                      SizedBox(width: context.responsive(14.0, 18.0, 22.0)),
                      // Next
                      Container(
                        width: context.responsive(40.0, 44.0, 48.0),
                        height: context.responsive(40.0, 44.0, 48.0),
                        decoration: BoxDecoration(
                          color: const Color(0xFF121212).withValues(alpha: 0.6),
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          onPressed: () => playerService.next(),
                          iconSize: context.responsive(18.0, 20.0, 22.0),
                          padding: EdgeInsets.zero,
                          icon: Icon(
                            LucideIcons.skipForward,
                            color: context.adaptiveTextPrimary,
                          ),
                        ),
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
          final buttonSize = context.responsive(58.0, 64.0, 68.0);
          final iconSize = context.responsive(26.0, 28.0, 30.0);
          
          return Container(
            width: buttonSize,
            height: buttonSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF121212).withValues(alpha: 0.6),
              boxShadow: [
                BoxShadow(
                  color: AppColors.accent.withValues(alpha: 0.4),
                  blurRadius: context.responsive(14.0, 18.0, 22.0),
                  offset: Offset(0, context.responsive(5.0, 6.0, 7.0)),
                ),
              ],
            ),
            child: IconButton(
              onPressed: () => playerService.togglePlayPause(),
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
