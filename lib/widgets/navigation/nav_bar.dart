import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/widgets/navigation/nav_button.dart';

/// Navigation destination enum for type-safe navigation.
enum NavDestination { menu, songs, settings }

/// Main glassmorphism navigation bar with three buttons.
class NavBar extends StatelessWidget {
  /// Currently selected navigation destination
  final NavDestination currentDestination;

  /// Callback when a destination is selected
  final ValueChanged<NavDestination> onDestinationChanged;

  const NavBar({
    super.key,
    required this.currentDestination,
    required this.onDestinationChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + AppConstants.spacingSm,
        top: AppConstants.spacingSm,
        left: AppConstants.spacingMd,
        right: AppConstants.spacingMd,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppConstants.radiusXl),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: AppConstants.glassBlurSigma,
            sigmaY: AppConstants.glassBlurSigma,
          ),
          child: Container(
            height: AppConstants.navBarHeight,
            padding: const EdgeInsets.symmetric(
              horizontal: AppConstants.spacingMd,
            ),
            decoration: BoxDecoration(
              color: AppColors.glassBackground,
              borderRadius: BorderRadius.circular(AppConstants.radiusXl),
              border: Border.all(color: AppColors.glassBorder, width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                NavButton(
                  icon: LucideIcons.menu,
                  label: 'Menu',
                  isActive: currentDestination == NavDestination.menu,
                  onTap: () => onDestinationChanged(NavDestination.menu),
                ),
                NavButton(
                  icon: LucideIcons.music,
                  label: 'Songs',
                  isActive: currentDestination == NavDestination.songs,
                  onTap: () => onDestinationChanged(NavDestination.songs),
                ),
                NavButton(
                  icon: LucideIcons.settings,
                  label: 'Settings',
                  isActive: currentDestination == NavDestination.settings,
                  onTap: () => onDestinationChanged(NavDestination.settings),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
