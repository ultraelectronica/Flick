import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flick/features/player/screens/full_player_screen.dart';

/// Helper class to prevent duplicate navigation to FullPlayerScreen
class NavigationHelper {
  // Track if navigation is in progress to prevent double navigation
  static bool _isNavigating = false;
  static Timer? _navigationTimer;

  // Track if FullPlayerScreen is currently open
  static bool _isFullPlayerOpen = false;

  /// Checks if FullPlayerScreen is already on the navigation stack
  static bool _isFullPlayerScreenOnStack(BuildContext context) {
    // First check our flag
    if (_isFullPlayerOpen) {
      return true;
    }

    // Check the current route
    final route = ModalRoute.of(context);
    if (route?.settings.name == '/full_player') {
      return true;
    }

    final navigator = Navigator.of(context);
    if (navigator.canPop()) return true;

    return false;
  }

  static Future<int?> navigateToFullPlayer(
    BuildContext context, {
    required String heroTag,
  }) async {
    // Prevent multiple simultaneous navigations
    if (_isNavigating || _isFullPlayerOpen) {
      return null;
    }

    // Check if FullPlayerScreen is already on the stack
    if (_isFullPlayerScreenOnStack(context)) {
      return null;
    }

    // Set flags immediately to prevent double navigation
    _isNavigating = true;
    _isFullPlayerOpen = true;

    // Clear any existing timer
    _navigationTimer?.cancel();

    // Reset navigation flag after navigation animation completes
    _navigationTimer = Timer(const Duration(milliseconds: 800), () {
      _isNavigating = false;
    });

    if (!context.mounted) {
      _isNavigating = false;
      _isFullPlayerOpen = false;
      _navigationTimer?.cancel();
      _navigationTimer = null;
      return null;
    }

    try {
      // Navigate to full player screen
      final result = await Navigator.of(context).push<int>(
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) =>
              FullPlayerScreen(heroTag: heroTag),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
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
          settings: const RouteSettings(name: '/full_player'),
        ),
      );

      // Reset flags after navigation completes (screen was popped)
      _isFullPlayerOpen = false;
      _isNavigating = false;
      _navigationTimer?.cancel();
      _navigationTimer = null;

      return result;
    } catch (e) {
      // If navigation fails, reset flags
      _isFullPlayerOpen = false;
      _isNavigating = false;
      _navigationTimer?.cancel();
      _navigationTimer = null;
      rethrow;
    }
  }
}
