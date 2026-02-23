import 'package:flutter/material.dart';
import 'package:flick/core/theme/app_colors.dart';

/// Utility class for computing contrast-aware colors based on background luminance.
///
/// This ensures text and UI elements remain readable regardless of the
/// underlying background color (e.g., when album art affects the ambient background).
class AdaptiveColors {
  AdaptiveColors._();

  // White smoke color variants for better visual appeal (near-white, warmer tones)
  static const Color _whiteSmokeLight = Color(
    0xFFF5F5F5,
  ); // Primary text - warm white
  static const Color _whiteSmokeMedium = Color(0xFFD0D0D0); // Secondary text
  static const Color _whiteSmokeDim = Color(0xFFA8A8A8); // Tertiary text
  static const Color _whiteSmokeAccent = Color(
    0xFFE8E8E8,
  ); // Accent - subtle highlight

  /// Computes the relative luminance of a color (0 = darkest, 1 = lightest).
  static double getLuminance(Color color) {
    return color.computeLuminance();
  }

  /// Returns whether a background is considered "dark" (luminance < 0.5).
  static bool isDark(Color backgroundColor) {
    return getLuminance(backgroundColor) < 0.5;
  }

  /// Returns an appropriate primary text color based on the background.
  /// Uses warm white smoke for dark backgrounds, dark gray for light backgrounds.
  static Color textPrimaryOn(Color backgroundColor) {
    return isDark(backgroundColor) ? _whiteSmokeLight : const Color(0xFF1A1A1A);
  }

  /// Returns an appropriate secondary text color based on the background.
  static Color textSecondaryOn(Color backgroundColor) {
    return isDark(backgroundColor)
        ? _whiteSmokeMedium
        : const Color(0xFF4A4A4A);
  }

  /// Returns an appropriate tertiary text color based on the background.
  static Color textTertiaryOn(Color backgroundColor) {
    return isDark(backgroundColor) ? _whiteSmokeDim : const Color(0xFF6A6A6A);
  }

  /// Returns an appropriate accent color based on the background.
  static Color accentOn(Color backgroundColor) {
    return isDark(backgroundColor)
        ? _whiteSmokeAccent
        : const Color(0xFF3A3A3A);
  }

  /// Returns an appropriate icon color based on the background.
  static Color iconOn(Color backgroundColor) {
    return textPrimaryOn(backgroundColor);
  }

  /// Returns the appropriate glassmorphism border color based on background.
  static Color glassBorderOn(Color backgroundColor) {
    return isDark(backgroundColor)
        ? AppColors.glassBorder
        : const Color(0x1A000000); // 10% black for light backgrounds
  }

  /// Returns the appropriate glassmorphism background color based on background.
  static Color glassBackgroundOn(Color backgroundColor) {
    return isDark(backgroundColor)
        ? AppColors.glassBackground
        : const Color(0x0D000000); // 5% black for light backgrounds
  }

  /// Computes a contrasting color that ensures minimum WCAG contrast ratio.
  /// [minContrast] should be at least 4.5 for normal text, 3.0 for large text.
  static Color ensureContrast(
    Color foreground,
    Color background, {
    double minContrast = 4.5,
  }) {
    final contrast = _contrastRatio(foreground, background);

    if (contrast >= minContrast) {
      return foreground;
    }

    // If contrast is insufficient, return black or white based on background
    return isDark(background) ? Colors.white : Colors.black;
  }

  /// Computes the contrast ratio between two colors (WCAG formula).
  static double _contrastRatio(Color foreground, Color background) {
    final l1 = getLuminance(foreground);
    final l2 = getLuminance(background);

    final lighter = l1 > l2 ? l1 : l2;
    final darker = l1 > l2 ? l2 : l1;

    return (lighter + 0.05) / (darker + 0.05);
  }

  /// Returns an appropriate selection/highlight color based on background.
  static Color selectionColorOn(Color backgroundColor) {
    return isDark(backgroundColor)
        ? AppColors.accentLight.withValues(alpha: 0.3)
        : const Color(0xFF3A3A3A).withValues(alpha: 0.2);
  }

  /// Returns shadow color adapted to the background.
  /// Lighter shadows for dark backgrounds, darker shadows for light backgrounds.
  static Color shadowOn(Color backgroundColor) {
    return isDark(backgroundColor)
        ? Colors.black.withValues(alpha: 0.4)
        : Colors.black.withValues(alpha: 0.2);
  }

  /// Blends a color to make it more visible against the given background.
  /// Useful for overlays and semi-transparent elements.
  static Color blendForVisibility(Color color, Color backgroundColor) {
    if (isDark(backgroundColor)) {
      // Lighten the color for dark backgrounds
      return Color.lerp(color, Colors.white, 0.1)!;
    } else {
      // Darken the color for light backgrounds
      return Color.lerp(color, Colors.black, 0.1)!;
    }
  }
}
