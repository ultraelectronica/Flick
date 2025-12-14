import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flick_player/core/theme/app_colors.dart';
import 'package:flick_player/core/constants/app_constants.dart';

/// A reusable glassmorphism container widget with frosted glass effect.
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
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
          child: Container(
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
          ),
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
