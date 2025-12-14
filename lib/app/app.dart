import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flick_player/core/theme/app_theme.dart';
import 'package:flick_player/core/theme/app_colors.dart';
import 'package:flick_player/widgets/navigation/nav_bar.dart';
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

class _MainShellState extends State<MainShell> {
  NavDestination _currentDestination = NavDestination.songs;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      extendBody: true,
      body: Stack(
        children: [
          // Main content area
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: _buildScreen(),
          ),

          // Navigation bar (always on top)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: NavBar(
              currentDestination: _currentDestination,
              onDestinationChanged: (destination) {
                setState(() {
                  _currentDestination = destination;
                });
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScreen() {
    switch (_currentDestination) {
      case NavDestination.menu:
        return const MenuScreen(key: ValueKey('menu'));
      case NavDestination.songs:
        return const SongsScreen(key: ValueKey('songs'));
      case NavDestination.settings:
        return const SettingsScreen(key: ValueKey('settings'));
    }
  }
}
