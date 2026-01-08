import 'package:flutter/material.dart';
import 'package:flick/core/theme/adaptive_colors.dart';
import 'package:flick/core/theme/app_colors.dart';

/// Provides background color context to descendant widgets for adaptive coloring.
///
/// Wrap your widget tree with this provider and use [AdaptiveColorProvider.of(context)]
/// to access the current background color and adaptive colors.
class AdaptiveColorProvider extends InheritedWidget {
  /// The current dominant background color.
  final Color backgroundColor;

  /// Optional: The source color extracted from album art.
  final Color? albumDominantColor;

  const AdaptiveColorProvider({
    super.key,
    required this.backgroundColor,
    this.albumDominantColor,
    required super.child,
  });

  /// Access the provider from the widget tree.
  static AdaptiveColorProvider? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<AdaptiveColorProvider>();
  }

  /// Access the provider from the widget tree (throws if not found).
  static AdaptiveColorProvider of(BuildContext context) {
    final provider = maybeOf(context);
    assert(provider != null, 'No AdaptiveColorProvider found in context');
    return provider!;
  }

  /// Get the effective background color, falling back to default if no provider.
  static Color effectiveBackgroundColor(BuildContext context) {
    return maybeOf(context)?.backgroundColor ?? AppColors.background;
  }

  /// Get adaptive text primary color based on current background.
  static Color textPrimary(BuildContext context) {
    return AdaptiveColors.textPrimaryOn(effectiveBackgroundColor(context));
  }

  /// Get adaptive text secondary color based on current background.
  static Color textSecondary(BuildContext context) {
    return AdaptiveColors.textSecondaryOn(effectiveBackgroundColor(context));
  }

  /// Get adaptive text tertiary color based on current background.
  static Color textTertiary(BuildContext context) {
    return AdaptiveColors.textTertiaryOn(effectiveBackgroundColor(context));
  }

  /// Get adaptive accent color based on current background.
  static Color accent(BuildContext context) {
    return AdaptiveColors.accentOn(effectiveBackgroundColor(context));
  }

  /// Get adaptive icon color based on current background.
  static Color icon(BuildContext context) {
    return AdaptiveColors.iconOn(effectiveBackgroundColor(context));
  }

  /// Get adaptive glass border color based on current background.
  static Color glassBorder(BuildContext context) {
    return AdaptiveColors.glassBorderOn(effectiveBackgroundColor(context));
  }

  /// Get adaptive glass background color based on current background.
  static Color glassBackground(BuildContext context) {
    return AdaptiveColors.glassBackgroundOn(effectiveBackgroundColor(context));
  }

  /// Returns true if the current background is considered dark.
  static bool isDark(BuildContext context) {
    return AdaptiveColors.isDark(effectiveBackgroundColor(context));
  }

  @override
  bool updateShouldNotify(AdaptiveColorProvider oldWidget) {
    return backgroundColor != oldWidget.backgroundColor ||
        albumDominantColor != oldWidget.albumDominantColor;
  }
}

/// Extension on BuildContext for convenient access to adaptive colors.
extension AdaptiveColorContext on BuildContext {
  /// Get the current effective background color.
  Color get adaptiveBackground =>
      AdaptiveColorProvider.effectiveBackgroundColor(this);

  /// Get adaptive text primary color.
  Color get adaptiveTextPrimary => AdaptiveColorProvider.textPrimary(this);

  /// Get adaptive text secondary color.
  Color get adaptiveTextSecondary => AdaptiveColorProvider.textSecondary(this);

  /// Get adaptive text tertiary color.
  Color get adaptiveTextTertiary => AdaptiveColorProvider.textTertiary(this);

  /// Get adaptive accent color.
  Color get adaptiveAccent => AdaptiveColorProvider.accent(this);

  /// Get adaptive icon color.
  Color get adaptiveIcon => AdaptiveColorProvider.icon(this);

  /// Check if current background is dark.
  bool get isAdaptiveBackgroundDark => AdaptiveColorProvider.isDark(this);
}
