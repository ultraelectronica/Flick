import 'package:flutter/material.dart';
import 'package:salomon_bottom_bar/salomon_bottom_bar.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';

/// A reusable glassmorphic navigation bar widget using SalomonBottomBar.
///
/// Can be used with or without the mini player section.
class SalomonNavBar extends StatelessWidget {
  /// Currently selected tab index (0: Menu, 1: Songs, 2: Settings)
  final int currentIndex;

  /// Callback when a tab is tapped
  final ValueChanged<int> onTap;

  /// Whether to include the mini player above the navigation items.
  /// When false, only the navigation bar is shown.
  final bool showMiniPlayer;

  /// Optional widget to display as the mini player.
  /// Only used when [showMiniPlayer] is true.
  final Widget? miniPlayerWidget;

  const SalomonNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.showMiniPlayer = false,
    this.miniPlayerWidget,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(24, -40, 24, 24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 20,
            spreadRadius: 2,
            offset: const Offset(0, 8),
          ),
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
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                AppColors.surfaceLight.withValues(alpha: 0.85),
                AppColors.surface.withValues(alpha: 0.92),
              ],
            ),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: AppColors.glassBorder, width: 1),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Optional Mini Player
              if (showMiniPlayer && miniPlayerWidget != null) miniPlayerWidget!,

              // Navigation Bar
              _buildNavigationItems(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavigationItems(BuildContext context) {
    // Adjust padding based on whether mini player is shown
    final padding = showMiniPlayer
        ? const EdgeInsets.fromLTRB(16, -35, 16, 7)
        : const EdgeInsets.fromLTRB(16, -40, 16, 12);

    final transform = showMiniPlayer
        ? Matrix4.translationValues(0, -8, 0)
        : Matrix4.identity();

    // Get adaptive colors based on background
    final selectedColor = context.adaptiveTextPrimary;
    final unselectedColor = context.adaptiveTextTertiary;
    final accentColor = context.adaptiveAccent;

    return Transform(
      transform: transform,
      child: Padding(
        padding: padding,
        child: SalomonBottomBar(
          currentIndex: currentIndex,
          onTap: onTap,
          margin: EdgeInsets.zero,
          itemPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          selectedItemColor: selectedColor,
          unselectedItemColor: unselectedColor,
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
              selectedColor: accentColor,
              unselectedColor: unselectedColor,
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
              selectedColor: accentColor,
              unselectedColor: unselectedColor,
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
              selectedColor: accentColor,
              unselectedColor: unselectedColor,
            ),
          ],
        ),
      ),
    );
  }
}
