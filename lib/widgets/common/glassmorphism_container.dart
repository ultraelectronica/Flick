import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/constants/app_constants.dart';

/// A reusable glassmorphism container widget.
///
/// Uses [useFilter] to toggle between BackdropFilter (expensive) and
/// simple semi-transparent container (budget-friendly for mobile).
/// Default is true for backward compatibility, set false for performance.
class GlassmorphismContainer extends StatelessWidget {
  /// Child widget to display inside the container
  final Widget child;

  /// Blur intensity for the frosted glass effect
  final double blurSigma;

  /// Background color with transparency
  final Color? backgroundColor;

  /// Border color
  final Color? borderColor;

  /// Border width
  final double borderWidth;

  /// Border radius
  final BorderRadius? borderRadius;

  /// Padding inside the container
  final EdgeInsets padding;

  /// Margin outside the container
  final EdgeInsets margin;

  /// Width constraint
  final double? width;

  /// Height constraint
  final double? height;

  /// Whether to use BackdropFilter (expensive on mobile GPUs).
  /// Set to false for budget-friendly semi-transparent panel.
  final bool useFilter;

  const GlassmorphismContainer({
    super.key,
    required this.child,
    this.blurSigma = AppConstants.glassBlurSigma,
    this.backgroundColor,
    this.borderColor,
    this.borderWidth = 1.0,
    this.borderRadius,
    this.padding = const EdgeInsets.all(AppConstants.spacingMd),
    this.margin = EdgeInsets.zero,
    this.width,
    this.height,
    this.useFilter = true,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveBorderRadius =
        borderRadius ?? BorderRadius.circular(AppConstants.radiusLg);

    return Container(
      margin: margin,
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: effectiveBorderRadius,
        child: useFilter
            ? BackdropFilter(
                filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
                child: _buildContainer(effectiveBorderRadius),
              )
            : _buildContainer(effectiveBorderRadius),
      ),
    );
  }

  Widget _buildContainer(BorderRadius effectiveBorderRadius) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: backgroundColor ?? AppColors.glassBackground,
        borderRadius: effectiveBorderRadius,
        border: Border.all(
          color: borderColor ?? AppColors.glassBorder,
          width: borderWidth,
        ),
      ),
      child: child,
    );
  }
}

/// A budget-friendly glassmorphism container without blur.
/// Prefer this for scrolling content and lists.
class GlassmorphismContainerSolid extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final EdgeInsets margin;
  final BorderRadius? borderRadius;
  final double? width;
  final double? height;
  final Color? backgroundColor;
  final Color? borderColor;

  const GlassmorphismContainerSolid({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppConstants.spacingMd),
    this.margin = EdgeInsets.zero,
    this.borderRadius,
    this.width,
    this.height,
    this.backgroundColor,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveBorderRadius =
        borderRadius ?? BorderRadius.circular(AppConstants.radiusLg);

    return Container(
      margin: margin,
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: effectiveBorderRadius,
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: backgroundColor ?? AppColors.glassBackground,
            borderRadius: effectiveBorderRadius,
            border: Border.all(
              color: borderColor ?? AppColors.glassBorder,
              width: 1.0,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// A preset glassmorphism container with stronger effect
class GlassmorphismContainerStrong extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final EdgeInsets margin;
  final BorderRadius? borderRadius;
  final double? width;
  final double? height;

  const GlassmorphismContainerStrong({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppConstants.spacingMd),
    this.margin = EdgeInsets.zero,
    this.borderRadius,
    this.width,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    return GlassmorphismContainer(
      blurSigma: AppConstants.glassBlurSigmaStrong,
      backgroundColor: AppColors.glassBackgroundStrong,
      borderColor: AppColors.glassBorderStrong,
      padding: padding,
      margin: margin,
      borderRadius: borderRadius,
      width: width,
      height: height,
      child: child,
    );
  }
}
