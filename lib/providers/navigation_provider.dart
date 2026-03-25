import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/color_extraction_service.dart';
import '../core/theme/app_colors.dart';
import 'player_provider.dart';

/// Navigation destinations in the app.
enum NavDestination { menu, songs, settings }

/// Notifier for navigation index state.
class NavigationIndexNotifier extends Notifier<int> {
  @override
  int build() => 1; // Default: songs

  void setIndex(int index) {
    state = index;
  }
}

/// State provider for the current navigation index.
final navigationIndexProvider = NotifierProvider<NavigationIndexNotifier, int>(
  NavigationIndexNotifier.new,
);

/// Notifier for nav bar visibility state.
class NavBarVisibleNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  void setVisible(bool visible) {
    state = visible;
  }
}

/// State provider for nav bar visibility.
final navBarVisibleProvider = NotifierProvider<NavBarVisibleNotifier, bool>(
  NavBarVisibleNotifier.new,
);

class NavBarAlwaysVisibleNotifier extends Notifier<bool> {
  static const _prefKey = 'nav_bar_always_visible';
  bool _initialized = false;

  @override
  bool build() {
    if (!_initialized) {
      _initialized = true;
      Future<void>.microtask(_loadPreference);
    }
    return false;
  }

  Future<void> _loadPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getBool(_prefKey) ?? false;
    if (!ref.mounted) return;
    state = value;

    if (value) {
      ref.read(navBarVisibleProvider.notifier).setVisible(true);
    }
  }

  Future<void> setAlwaysVisible(bool value) async {
    if (state == value) return;
    state = value;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, value);

    if (value) {
      ref.read(navBarVisibleProvider.notifier).setVisible(true);
    }
  }
}

final navBarAlwaysVisibleProvider =
    NotifierProvider<NavBarAlwaysVisibleNotifier, bool>(
      NavBarAlwaysVisibleNotifier.new,
    );

class AmbientBackgroundEnabledNotifier extends Notifier<bool> {
  static const _prefKey = 'ambient_background_enabled';
  bool _initialized = false;

  @override
  bool build() {
    if (!_initialized) {
      _initialized = true;
      Future<void>.microtask(_loadPreference);
    }
    return true;
  }

  Future<void> _loadPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getBool(_prefKey) ?? true;
    if (!ref.mounted) return;
    state = value;
  }

  Future<void> setEnabled(bool value) async {
    if (state == value) return;
    state = value;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, value);
  }
}

final ambientBackgroundEnabledProvider =
    NotifierProvider<AmbientBackgroundEnabledNotifier, bool>(
      AmbientBackgroundEnabledNotifier.new,
    );

// ============================================================================
// Background color extraction
// ============================================================================

/// Provider for the ColorExtractionService.
final colorExtractionServiceProvider = Provider<ColorExtractionService>((ref) {
  return ColorExtractionService();
});

/// Extracted background color from current song's album art.
/// Updates reactively when the current song changes.
final adaptiveBackgroundColorProvider = FutureProvider.autoDispose<Color>((
  ref,
) async {
  final ambientBackgroundEnabled = ref.watch(ambientBackgroundEnabledProvider);
  final currentSong = ref.watch(currentSongProvider);
  final colorService = ref.watch(colorExtractionServiceProvider);

  if (!ambientBackgroundEnabled) {
    return AppColors.background;
  }

  if (currentSong?.albumArt != null) {
    return colorService.extractBlendedBackgroundColor(
      currentSong!.albumArt,
      blendFactor: 0.3,
    );
  }

  return AppColors.background;
});

/// Synchronous version with fallback color.
final backgroundColorProvider = Provider<Color>((ref) {
  return ref.watch(adaptiveBackgroundColorProvider).value ??
      AppColors.background;
});
