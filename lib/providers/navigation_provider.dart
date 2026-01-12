import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  final currentSong = ref.watch(currentSongProvider);
  final colorService = ref.watch(colorExtractionServiceProvider);

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
