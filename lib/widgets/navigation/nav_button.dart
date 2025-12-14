import 'package:flutter/material.dart';
import 'package:flick_player/core/theme/app_colors.dart';
import 'package:flick_player/core/constants/app_constants.dart';

/// Individual navigation button with icon and label.
class NavButton extends StatefulWidget {
  /// Icon to display
  final IconData icon;

  /// Label text below the icon
  final String label;

  /// Whether this button is currently active/selected
  final bool isActive;

  /// Callback when button is tapped
  final VoidCallback onTap;

  const NavButton({
    super.key,
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  State<NavButton> createState() => _NavButtonState();
}

class _NavButtonState extends State<NavButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: AppConstants.animationFast,
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.92).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails details) {
    _animationController.forward();
  }

  void _onTapUp(TapUpDetails details) {
    _animationController.reverse();
    widget.onTap();
  }

  void _onTapCancel() {
    _animationController.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.isActive
        ? AppColors.activeState
        : AppColors.inactiveState;

    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      child: AnimatedBuilder(
        animation: _scaleAnimation,
        builder: (context, child) {
          return Transform.scale(scale: _scaleAnimation.value, child: child);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppConstants.spacingLg,
            vertical: AppConstants.spacingSm,
          ),
          decoration: BoxDecoration(
            color: widget.isActive
                ? AppColors.glassBackgroundStrong
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppConstants.radiusMd),
            border: widget.isActive
                ? Border.all(color: AppColors.glassBorder, width: 1)
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.icon,
                size: AppConstants.navBarIconSize,
                color: color,
              ),
              const SizedBox(height: AppConstants.spacingXxs),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: widget.isActive
                      ? FontWeight.w600
                      : FontWeight.w400,
                  color: color,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
