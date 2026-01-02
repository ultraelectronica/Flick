import 'dart:ui';
import 'package:salomon_bottom_bar/salomon_bottom_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_theme.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/features/songs/screens/songs_screen.dart';
import 'package:flick/features/menu/screens/menu_screen.dart';
import 'package:flick/features/settings/screens/settings_screen.dart';
import 'package:flick/features/player/widgets/mini_player.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/features/player/widgets/ambient_background.dart';

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

  // Use ValueNotifier for nav bar visibility to avoid full widget rebuilds
  final ValueNotifier<bool> _isNavBarVisible = ValueNotifier(true);

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
  }

  @override
  void dispose() {
    _isNavBarVisible.removeListener(_onNavBarVisibilityChanged);
    _isNavBarVisible.dispose();
    _navBarAnimationController.dispose();
    super.dispose();
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
    return Scaffold(
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
              children: const [
                MenuScreen(key: ValueKey('menu')),
                SongsScreen(key: ValueKey('songs')),
                SettingsScreen(key: ValueKey('settings')),
              ],
            ),

            // Mini Player with animated position
            AnimatedBuilder(
              animation: _navBarAnimationController,
              builder: (context, child) {
                // Controller 0.0 (Visible) -> Bottom: NavBarHeight + 24
                // Controller 1.0 (Hidden)  -> Bottom: 24 (just margin)
                final double bottom =
                    lerpDouble(
                      AppConstants.navBarHeight + 24,
                      24,
                      _navBarAnimationController.value,
                    ) ??
                    24;

                return Positioned(
                  left: 0,
                  right: 0,
                  bottom: bottom,
                  child: const MiniPlayer(),
                );
              },
            ),

            // Navigation bar with isolated repaints
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: RepaintBoundary(
                child: SlideTransition(
                  position: _navBarSlideAnimation,
                  child: _buildNavigationBar(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavigationBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        // Outer glow effect for premium feel
        boxShadow: [
          // Primary shadow
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 20,
            spreadRadius: 2,
            offset: const Offset(0, 8),
          ),
          // Subtle ambient glow
          BoxShadow(
            color: AppColors.accent.withValues(alpha: 0.05),
            blurRadius: 32,
            spreadRadius: -4,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, -40, 16, 16),
          decoration: BoxDecoration(
            // Glassmorphism background
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                AppColors.surfaceLight.withValues(alpha: 0.85),
                AppColors.surface.withValues(alpha: 0.92),
              ],
            ),
            borderRadius: BorderRadius.circular(28),
            // Subtle border for depth
            border: Border.all(color: AppColors.glassBorder, width: 1),
          ),
          child: SalomonBottomBar(
            currentIndex: _currentIndex,
            onTap: (index) {
              if (_currentIndex != index) {
                setState(() {
                  _currentIndex = index;
                });
              }
            },
            margin: EdgeInsets.zero,
            itemPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 10,
            ),
            selectedItemColor: AppColors.textPrimary,
            unselectedItemColor: AppColors.textTertiary,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutQuart,
            items: [
              SalomonBottomBarItem(
                icon: const Icon(LucideIcons.layoutGrid, size: 20),
                title: const Text(
                  'Menu',
                  style: TextStyle(
                    fontFamily: 'ProductSans',
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
                selectedColor: AppColors.accentLight,
                unselectedColor: AppColors.textTertiary,
              ),
              SalomonBottomBarItem(
                icon: const Icon(LucideIcons.disc3, size: 20),
                title: const Text(
                  'Songs',
                  style: TextStyle(
                    fontFamily: 'ProductSans',
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
                selectedColor: AppColors.accentLight,
                unselectedColor: AppColors.textTertiary,
              ),
              SalomonBottomBarItem(
                icon: const Icon(LucideIcons.settings2, size: 20),
                title: const Text(
                  'Settings',
                  style: TextStyle(
                    fontFamily: 'ProductSans',
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
                selectedColor: AppColors.accentLight,
                unselectedColor: AppColors.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
