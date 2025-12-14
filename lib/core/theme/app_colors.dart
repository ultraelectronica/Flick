import 'package:flutter/material.dart';

/// Monochrome color palette with glassmorphism support for Flick Player.
class AppColors {
  AppColors._();

  // Primary Background Colors
  static const Color background = Color(0xFF0A0A0A);
  static const Color backgroundLight = Color(0xFF1A1A1A);
  static const Color backgroundDark = Color(0xFF050505);

  // Surface Colors (for cards, containers)
  static const Color surface = Color(0xFF141414);
  static const Color surfaceLight = Color(0xFF1E1E1E);
  static const Color surfaceDark = Color(0xFF0C0C0C);

  // Text Colors
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFB0B0B0);
  static const Color textTertiary = Color(0xFF707070);

  // Accent Colors (subtle silver/white highlights)
  static const Color accent = Color(0xFFE0E0E0);
  static const Color accentLight = Color(0xFFF5F5F5);
  static const Color accentDim = Color(0xFF808080);

  // Glassmorphism Colors
  static const Color glassBackground = Color(0x0DFFFFFF); // 5% white
  static const Color glassBackgroundStrong = Color(0x26FFFFFF); // 15% white
  static const Color glassBorder = Color(0x1AFFFFFF); // 10% white
  static const Color glassBorderStrong = Color(0x33FFFFFF); // 20% white

  // State Colors
  static const Color activeState = Color(0xFFFFFFFF);
  static const Color inactiveState = Color(0xFF606060);

  // Gradient definitions
  static const LinearGradient backgroundGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [background, backgroundDark],
  );

  static const LinearGradient surfaceGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [surfaceLight, surface],
  );

  static const RadialGradient glowGradient = RadialGradient(
    colors: [Color(0x20FFFFFF), Color(0x00FFFFFF)],
  );
}
