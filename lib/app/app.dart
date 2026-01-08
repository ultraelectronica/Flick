import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_theme.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/features/songs/screens/songs_screen.dart';
import 'package:flick/features/menu/screens/menu_screen.dart';
import 'package:flick/features/settings/screens/settings_screen.dart';
import 'package:flick/features/player/screens/full_player_screen.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/color_extraction_service.dart';
import 'package:flick/features/player/widgets/ambient_background.dart';
import 'package:flick/widgets/navigation/salomon_nav_bar.dart';

/// Main application widget for Flick Player.
class FlickPlayerApp extends StatelessWidget {
  const FlickPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Set system UI overlay style for immersive experience
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: AppColors.background,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );

    return MaterialApp(
      title: 'Flick Player',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const MainShell(),
    );
  }
}

/// Main shell widget that contains navigation and screens.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

enum NavDestination { menu, songs, settings }

class _MainShellState extends State<MainShell>
    with SingleTickerProviderStateMixin {
  int _currentIndex = 1; // Default to songs (middle)
  final PlayerService _playerService = PlayerService();
  final ColorExtractionService _colorService = ColorExtractionService();

  // Use ValueNotifier for nav bar visibility to avoid full widget rebuilds
  final ValueNotifier<bool> _isNavBarVisible = ValueNotifier(true);

  // Track the current effective background color for adaptive theming
  final ValueNotifier<Color> _backgroundColorNotifier = ValueNotifier(
    AppColors.background,
  );

  // Animation controller for smoother nav bar transitions
  late final AnimationController _navBarAnimationController;
  late final Animation<Offset> _navBarSlideAnimation;

  @override
  void initState() {
    super.initState();
    _navBarAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(
        milliseconds: 280,
      ), // Balanced: not too fast, not too slow
    );
    _navBarSlideAnimation =
        Tween<Offset>(
          begin: Offset.zero,
          end: const Offset(0, 1.15), // Subtle slide distance
        ).animate(
          CurvedAnimation(
            parent: _navBarAnimationController,
            curve: Curves.easeOutCubic, // Smooth, natural hide
            reverseCurve: Curves.easeOutCubic, // Consistent smooth return
          ),
        );

    // Listen to visibility changes and trigger animation
    _isNavBarVisible.addListener(_onNavBarVisibilityChanged);

    // Listen to song changes to update background color
    _playerService.currentSongNotifier.addListener(_updateBackgroundColor);
    // Initial extraction
    _updateBackgroundColor();
  }

  @override
  void dispose() {
    _playerService.currentSongNotifier.removeListener(_updateBackgroundColor);
    _isNavBarVisible.removeListener(_onNavBarVisibilityChanged);
    _isNavBarVisible.dispose();
    _backgroundColorNotifier.dispose();
    _navBarAnimationController.dispose();
    super.dispose();
  }

  /// Extracts dominant color from current song's album art and updates background color.
  void _updateBackgroundColor() async {
    final song = _playerService.currentSongNotifier.value;
    if (song?.albumArt != null) {
      final color = await _colorService.extractBlendedBackgroundColor(
        song!.albumArt,
        blendFactor: 0.3, // Subtle blend with base background
      );
      if (mounted) {
        _backgroundColorNotifier.value = color;
      }
    } else {
      if (mounted) {
        _backgroundColorNotifier.value = AppColors.background;
      }
    }
  }

  void _onNavBarVisibilityChanged() {
    if (_isNavBarVisible.value) {
      _navBarAnimationController.reverse();
    } else {
      _navBarAnimationController.forward();
    }
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is UserScrollNotification) {
      final direction = notification.direction;
      final currentVisibility = _isNavBarVisible.value;

      if (direction == ScrollDirection.forward && currentVisibility) {
        // Scrolling down (content moving up) -> Hide Nav Bar
        _isNavBarVisible.value = false;
      } else if (direction == ScrollDirection.reverse && !currentVisibility) {
        // Scrolling up (content moving down) -> Show Nav Bar
        _isNavBarVisible.value = true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Color>(
      valueListenable: _backgroundColorNotifier,
      builder: (context, backgroundColor, _) {
        return AdaptiveColorProvider(
          backgroundColor: backgroundColor,
          child: Scaffold(
            backgroundColor: AppColors.background,
            extendBody: true,
            body: NotificationListener<ScrollNotification>(
              onNotification: _handleScrollNotification,
              child: Stack(
                children: [
                  // Base Gradient
                  Container(
                    decoration: const BoxDecoration(
                      gradient: AppColors.backgroundGradient,
                    ),
                  ),

                  // Persistent Background
                  Positioned.fill(
                    child: ValueListenableBuilder<Song?>(
                      valueListenable: _playerService.currentSongNotifier,
                      builder: (context, song, _) {
                        return AmbientBackground(song: song);
                      },
                    ),
                  ),

                  // Main content area with IndexedStack for faster tab switching
                  // Adjusted padding to ensure content isn't hidden behind MiniPlayer
                  IndexedStack(
                    index: _currentIndex,
                    children: [
                      MenuScreen(
                        key: const ValueKey('menu'),
                        onNavigateToTab: (index) {
                          setState(() {
                            _currentIndex = index;
                          });
                        },
                      ),
                      SongsScreen(
                        key: const ValueKey('songs'),
                        onNavigationRequested: (index) {
                          setState(() {
                            _currentIndex = index;
                          });
                        },
                      ),
                      const SettingsScreen(key: ValueKey('settings')),
                    ],
                  ),

                  // Unified Bottom Bar (Mini Player + Navigation)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: RepaintBoundary(
                      child: SlideTransition(
                        position: _navBarSlideAnimation,
                        child: _buildUnifiedBottomBar(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildUnifiedBottomBar() {
    return SalomonNavBar(
      currentIndex: _currentIndex,
      onTap: (index) {
        if (_currentIndex != index) {
          setState(() {
            _currentIndex = index;
          });
        }
      },
      showMiniPlayer: true,
      miniPlayerWidget: _buildEmbeddedMiniPlayer(),
    );
  }

  Widget _buildEmbeddedMiniPlayer() {
    return ValueListenableBuilder<Song?>(
      valueListenable: _playerService.currentSongNotifier,
      builder: (context, song, child) {
        if (song == null) {
          return const SizedBox.shrink();
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () async {
            final result = await Navigator.of(context).push<int>(
              PageRouteBuilder(
                pageBuilder: (context, animation, secondaryAnimation) =>
                    const FullPlayerScreen(heroTag: 'mini_player_art'),
                transitionsBuilder:
                    (context, animation, secondaryAnimation, child) {
                      const begin = Offset(0.0, 1.0);
                      const end = Offset.zero;
                      const curve = Curves.easeOutCubic;

                      var tween = Tween(
                        begin: begin,
                        end: end,
                      ).chain(CurveTween(curve: curve));

                      return SlideTransition(
                        position: animation.drive(tween),
                        child: child,
                      );
                    },
                transitionDuration: const Duration(milliseconds: 300),
                opaque: false,
                barrierColor: Colors.black,
              ),
            );
            // Navigate to the returned tab index if provided
            if (result != null && mounted) {
              setState(() {
                _currentIndex = result;
              });
            }
          },
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            height: 56,
            decoration: BoxDecoration(
              color: AppColors.glassBackground.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: AppColors.glassBorder.withValues(alpha: 0.2),
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                children: [
                  // Progress Bar at bottom
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
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(16),
                              bottomLeft: Radius.circular(16),
                            ),
                            image: song.albumArt != null
                                ? DecorationImage(
                                    image: FileImage(File(song.albumArt!)),
                                    fit: BoxFit.cover,
                                  )
                                : null,
                          ),
                          child: song.albumArt == null
                              ? const Icon(
                                  LucideIcons.music,
                                  size: 22,
                                  color: AppColors.textTertiary,
                                )
                              : null,
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
                                fontSize: 14,
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
                                fontSize: 12,
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
                              size: 20,
                            ),
                          );
                        },
                      ),
                      const SizedBox(width: 4),
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
