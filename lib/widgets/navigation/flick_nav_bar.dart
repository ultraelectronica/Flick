import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/utils/responsive.dart';

/// Navigation destination enum for type-safe navigation.
enum NavDestination { menu, songs, settings }

/// Navigation item data model.
class _NavItem {
  final String iconPath;
  final String label;
  final NavDestination destination;

  const _NavItem({
    required this.iconPath,
    required this.label,
    required this.destination,
  });
}

class FlickNavBar extends StatelessWidget {
  /// Currently selected navigation destination
  final int currentIndex;

  /// Callback when a destination is selected
  final ValueChanged<int> onTap;

  /// Whether to show the mini player above the nav bar
  final bool showMiniPlayer;

  /// Optional widget to display as the mini player
  final Widget? miniPlayerWidget;

  const FlickNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.showMiniPlayer = false,
    this.miniPlayerWidget,
  });

  static const List<_NavItem> _navItems = [
    _NavItem(
      iconPath: 'assets/icons/svg/menu_white.svg',
      label: 'Menu',
      destination: NavDestination.menu,
    ),
    _NavItem(
      iconPath: 'assets/icons/svg/record_vinyl_white.svg',
      label: 'Songs',
      destination: NavDestination.songs,
    ),
    _NavItem(
      iconPath: 'assets/icons/svg/settings_white.svg',
      label: 'Settings',
      destination: NavDestination.settings,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final horizontalPadding = context.scaleSize(AppConstants.spacingLg);
    final verticalPadding = context.scaleSize(AppConstants.spacingSm);

    return Container(
      margin: EdgeInsets.fromLTRB(
        horizontalPadding,
        0,
        horizontalPadding,
        bottomPadding + verticalPadding,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(context.scaleSize(20)),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: AppConstants.glassBlurSigma,
            sigmaY: AppConstants.glassBlurSigma,
          ),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AppColors.surfaceLight.withValues(alpha: 0.75),
                  AppColors.surface.withValues(alpha: 0.85),
                ],
              ),
              borderRadius: BorderRadius.circular(context.scaleSize(28)),
              border: Border.all(color: AppColors.glassBorder, width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 24,
                  spreadRadius: 2,
                  offset: const Offset(0, 10),
                ),
                BoxShadow(
                  color: AppColors.accent.withValues(alpha: 0.03),
                  blurRadius: 40,
                  spreadRadius: -8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Optional Mini Player
                if (showMiniPlayer && miniPlayerWidget != null)
                  miniPlayerWidget!,

                // Navigation Items
                _buildNavigationRow(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavigationRow(BuildContext context) {
    final itemPadding = context.scaleSize(AppConstants.spacingMd);

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: itemPadding,
        vertical: context.scaleSize(AppConstants.spacingXs),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: List.generate(
          _navItems.length,
          (index) => _FlickNavItem(
            item: _navItems[index],
            isSelected: currentIndex == index,
            onTap: () => onTap(index),
          ),
        ),
      ),
    );
  }
}

/// Individual navigation item with animations.
class _FlickNavItem extends StatefulWidget {
  final _NavItem item;
  final bool isSelected;
  final VoidCallback onTap;

  const _FlickNavItem({
    required this.item,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_FlickNavItem> createState() => _FlickNavItemState();
}

class _FlickNavItemState extends State<_FlickNavItem>
    with TickerProviderStateMixin {
  late final AnimationController _scaleController;
  late final AnimationController _selectionController;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _selectionAnimation;
  late final Animation<double> _iconScaleAnimation;

  @override
  void initState() {
    super.initState();

    // Scale animation for tap feedback
    _scaleController = AnimationController(
      duration: AppConstants.animationFast,
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.9).animate(
      CurvedAnimation(parent: _scaleController, curve: Curves.easeOutCubic),
    );

    // Selection animation for smooth state transitions
    _selectionController = AnimationController(
      duration: AppConstants.animationNormal,
      vsync: this,
      value: widget.isSelected ? 1.0 : 0.0,
    );
    _selectionAnimation = CurvedAnimation(
      parent: _selectionController,
      curve: Curves.easeOutQuart,
    );

    // Icon scale animation when selected
    _iconScaleAnimation = Tween<double>(begin: 1.0, end: 1.1).animate(
      CurvedAnimation(parent: _selectionController, curve: Curves.easeOutBack),
    );
  }

  @override
  void didUpdateWidget(_FlickNavItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isSelected != widget.isSelected) {
      if (widget.isSelected) {
        _selectionController.forward();
      } else {
        _selectionController.reverse();
      }
    }
  }

  @override
  void dispose() {
    _scaleController.dispose();
    _selectionController.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails details) {
    _scaleController.forward();
  }

  void _onTapUp(TapUpDetails details) {
    _scaleController.reverse();
    widget.onTap();
  }

  void _onTapCancel() {
    _scaleController.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final iconSize = context.responsiveIcon(AppConstants.iconSizeSm);
    final fontSize = context.responsiveText(8.0);
    final horizontalPadding = context.scaleSize(AppConstants.spacingMd);
    final verticalPadding = context.scaleSize(AppConstants.spacingXs);
    final spacing = context.scaleSize(2.0);

    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      child: AnimatedBuilder(
        animation: Listenable.merge([_scaleAnimation, _selectionAnimation]),
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnimation.value,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: horizontalPadding,
                vertical: verticalPadding,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Icon with scale animation
                  Transform.scale(
                    scale: _iconScaleAnimation.value,
                    child: SvgPicture.asset(
                      widget.item.iconPath,
                      width: iconSize,
                      height: iconSize,
                      colorFilter: ColorFilter.mode(
                        Color.lerp(
                          AppColors.inactiveState,
                          AppColors.activeState,
                          _selectionAnimation.value,
                        )!,
                        BlendMode.srcIn,
                      ),
                    ),
                  ),

                  SizedBox(height: spacing),

                  // Label with opacity animation
                  Text(
                    widget.item.label,
                    style: TextStyle(
                      fontFamily: 'ProductSans',
                      fontSize: fontSize,
                      fontWeight: widget.isSelected
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: Color.lerp(
                        AppColors.inactiveState,
                        AppColors.activeState,
                        _selectionAnimation.value,
                      ),
                      letterSpacing: 0.4,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
