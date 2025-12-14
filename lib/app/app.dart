import 'package:curved_navigation_bar/curved_navigation_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick_player/core/theme/app_theme.dart';
import 'package:flick_player/core/theme/app_colors.dart';
import 'package:flick_player/features/songs/screens/songs_screen.dart';
import 'package:flick_player/features/menu/screens/menu_screen.dart';
import 'package:flick_player/features/settings/screens/settings_screen.dart';

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

  // Use ValueNotifier for nav bar visibility to avoid full widget rebuilds
  final ValueNotifier<bool> _isNavBarVisible = ValueNotifier(true);

  // Animation controller for smoother nav bar transitions
  late final AnimationController _navBarAnimationController;
  late final Animation<Offset> _navBarSlideAnimation;

  final GlobalKey<CurvedNavigationBarState> _bottomNavigationKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _navBarAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _navBarSlideAnimation =
        Tween<Offset>(
          begin: Offset.zero,
          end: const Offset(0, 1.5), // Slide down to hide
        ).animate(
          CurvedAnimation(
            parent: _navBarAnimationController,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
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
            // Main content area with IndexedStack for faster tab switching
            IndexedStack(
              index: _currentIndex,
              children: const [
                MenuScreen(key: ValueKey('menu')),
                SongsScreen(key: ValueKey('songs')),
                SettingsScreen(key: ValueKey('settings')),
              ],
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
    return CurvedNavigationBar(
      key: _bottomNavigationKey,
      index: _currentIndex,
      height: 60.0,
      backgroundColor: Colors.transparent,
      color: AppColors.surfaceLight.withValues(alpha: 0.9),
      buttonBackgroundColor: AppColors.accent,
      animationDuration: const Duration(milliseconds: 250),
      animationCurve: Curves.easeOutCubic,
      onTap: (index) {
        if (_currentIndex != index) {
          setState(() {
            _currentIndex = index;
          });
        }
      },
      items: [
        Icon(
          LucideIcons.menu,
          size: 24,
          color: _currentIndex == 0 ? Colors.black : Colors.white,
        ),
        Icon(
          LucideIcons.music,
          size: 24,
          color: _currentIndex == 1 ? Colors.black : Colors.white,
        ),
        Icon(
          LucideIcons.settings,
          size: 24,
          color: _currentIndex == 2 ? Colors.black : Colors.white,
        ),
      ],
    );
  }
}
