import 'package:flutter/widgets.dart';

/// Breakpoints for responsive design.
enum ScreenSize { compact, phone, tablet, desktop }

/// Responsive utilities for adaptive sizing based on screen dimensions.
class Responsive {
  Responsive._();

  // Breakpoint thresholds (logical pixels)
  static const double compactWidth = 360;
  static const double phoneWidth = 600;
  static const double tabletWidth = 900;

  /// Get the current screen size category.
  static ScreenSize getScreenSize(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width < compactWidth) return ScreenSize.compact;
    if (width < phoneWidth) return ScreenSize.phone;
    if (width < tabletWidth) return ScreenSize.tablet;
    return ScreenSize.desktop;
  }

  /// Check if device is compact (small phone).
  static bool isCompact(BuildContext context) =>
      MediaQuery.sizeOf(context).width < compactWidth;

  /// Check if device is phone-sized.
  static bool isPhone(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return width >= compactWidth && width < phoneWidth;
  }

  /// Check if device is tablet-sized.
  static bool isTablet(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return width >= phoneWidth && width < tabletWidth;
  }

  /// Check if device is desktop-sized.
  static bool isDesktop(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= tabletWidth;

  /// Get a value based on screen size.
  /// Returns [compact] for small phones, [phone] for regular phones,
  /// [tablet] for tablets, and [desktop] for larger screens.
  static T value<T>(
    BuildContext context, {
    required T compact,
    T? phone,
    T? tablet,
    T? desktop,
  }) {
    final screenSize = getScreenSize(context);
    switch (screenSize) {
      case ScreenSize.compact:
        return compact;
      case ScreenSize.phone:
        return phone ?? compact;
      case ScreenSize.tablet:
        return tablet ?? phone ?? compact;
      case ScreenSize.desktop:
        return desktop ?? tablet ?? phone ?? compact;
    }
  }

  /// Scale a value proportionally based on screen width.
  /// Uses 375 (iPhone SE/8) as the base width.
  static double scale(BuildContext context, double value) {
    const baseWidth = 375.0;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final scaleFactor = (screenWidth / baseWidth).clamp(0.85, 1.5);
    return value * scaleFactor;
  }

  /// Get responsive text size that respects both screen size and text scale.
  static double textSize(BuildContext context, double baseSize) {
    final scaledSize = scale(context, baseSize);
    // Clamp text scale factor to prevent excessive scaling
    final textScaleFactor = MediaQuery.textScalerOf(
      context,
    ).clamp(minScaleFactor: 0.8, maxScaleFactor: 1.3).scale(1.0);
    return scaledSize * textScaleFactor;
  }

  /// Get responsive icon size.
  static double iconSize(BuildContext context, double baseSize) {
    return scale(context, baseSize);
  }

  /// Get responsive spacing.
  static double spacing(BuildContext context, double baseSpacing) {
    return scale(context, baseSpacing);
  }

  /// Get responsive padding with optional per-side customization.
  static EdgeInsets padding(
    BuildContext context, {
    double? all,
    double? horizontal,
    double? vertical,
    double? left,
    double? top,
    double? right,
    double? bottom,
  }) {
    if (all != null) {
      final scaled = scale(context, all);
      return EdgeInsets.all(scaled);
    }
    return EdgeInsets.only(
      left: scale(context, left ?? horizontal ?? 0),
      top: scale(context, top ?? vertical ?? 0),
      right: scale(context, right ?? horizontal ?? 0),
      bottom: scale(context, bottom ?? vertical ?? 0),
    );
  }

  /// Get grid column count based on screen width.
  static int gridColumns(
    BuildContext context, {
    int? compact,
    int? phone,
    int? tablet,
    int? desktop,
  }) {
    return value(
      context,
      compact: compact ?? 2,
      phone: phone ?? 2,
      tablet: tablet ?? 3,
      desktop: desktop ?? 4,
    );
  }
}

/// Extension methods for convenient responsive access via BuildContext.
extension ResponsiveContext on BuildContext {
  /// Get a value based on screen size.
  T responsive<T>(T compact, [T? phone, T? tablet, T? desktop]) {
    return Responsive.value(
      this,
      compact: compact,
      phone: phone,
      tablet: tablet,
      desktop: desktop,
    );
  }

  /// Scale a value proportionally based on screen width.
  double scaleSize(double value) => Responsive.scale(this, value);

  /// Get responsive text size.
  double responsiveText(double baseSize) => Responsive.textSize(this, baseSize);

  /// Get responsive icon size.
  double responsiveIcon(double baseSize) => Responsive.iconSize(this, baseSize);

  /// Get responsive spacing.
  double responsiveSpacing(double baseSpacing) =>
      Responsive.spacing(this, baseSpacing);

  /// Get responsive padding.
  EdgeInsets responsivePadding({
    double? all,
    double? horizontal,
    double? vertical,
    double? left,
    double? top,
    double? right,
    double? bottom,
  }) {
    return Responsive.padding(
      this,
      all: all,
      horizontal: horizontal,
      vertical: vertical,
      left: left,
      top: top,
      right: right,
      bottom: bottom,
    );
  }

  /// Get grid column count.
  int gridColumns({int? compact, int? phone, int? tablet, int? desktop}) {
    return Responsive.gridColumns(
      this,
      compact: compact,
      phone: phone,
      tablet: tablet,
      desktop: desktop,
    );
  }

  /// Current screen size category.
  ScreenSize get screenSize => Responsive.getScreenSize(this);

  /// Screen width.
  double get screenWidth => MediaQuery.sizeOf(this).width;

  /// Screen height.
  double get screenHeight => MediaQuery.sizeOf(this).height;

  /// Is compact screen (small phone).
  bool get isCompact => Responsive.isCompact(this);

  /// Is regular phone.
  bool get isPhone => Responsive.isPhone(this);

  /// Is tablet.
  bool get isTablet => Responsive.isTablet(this);

  /// Is desktop.
  bool get isDesktop => Responsive.isDesktop(this);
}
