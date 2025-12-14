import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_colors.dart';

/// App theme configuration with Proxima Nova-like font (Montserrat) and dark theme.
class AppTheme {
  AppTheme._();

  /// Primary text theme using Montserrat (closest Google Font to Proxima Nova)
  static TextTheme get _textTheme {
    return TextTheme(
      // Display styles
      displayLarge: GoogleFonts.montserrat(
        fontSize: 57,
        fontWeight: FontWeight.w300,
        letterSpacing: -0.25,
        color: AppColors.textPrimary,
      ),
      displayMedium: GoogleFonts.montserrat(
        fontSize: 45,
        fontWeight: FontWeight.w300,
        color: AppColors.textPrimary,
      ),
      displaySmall: GoogleFonts.montserrat(
        fontSize: 36,
        fontWeight: FontWeight.w400,
        color: AppColors.textPrimary,
      ),

      // Headline styles
      headlineLarge: GoogleFonts.montserrat(
        fontSize: 32,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
      headlineMedium: GoogleFonts.montserrat(
        fontSize: 28,
        fontWeight: FontWeight.w500,
        color: AppColors.textPrimary,
      ),
      headlineSmall: GoogleFonts.montserrat(
        fontSize: 24,
        fontWeight: FontWeight.w500,
        color: AppColors.textPrimary,
      ),

      // Title styles
      titleLarge: GoogleFonts.montserrat(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
      titleMedium: GoogleFonts.montserrat(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.15,
        color: AppColors.textPrimary,
      ),
      titleSmall: GoogleFonts.montserrat(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.1,
        color: AppColors.textPrimary,
      ),

      // Body styles
      bodyLarge: GoogleFonts.montserrat(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.5,
        color: AppColors.textPrimary,
      ),
      bodyMedium: GoogleFonts.montserrat(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.25,
        color: AppColors.textSecondary,
      ),
      bodySmall: GoogleFonts.montserrat(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.4,
        color: AppColors.textTertiary,
      ),

      // Label styles
      labelLarge: GoogleFonts.montserrat(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.1,
        color: AppColors.textPrimary,
      ),
      labelMedium: GoogleFonts.montserrat(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
        color: AppColors.textSecondary,
      ),
      labelSmall: GoogleFonts.montserrat(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
        color: AppColors.textTertiary,
      ),
    );
  }

  /// Dark theme for the app
  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.background,

      // Color scheme
      colorScheme: const ColorScheme.dark(
        primary: AppColors.textPrimary,
        onPrimary: AppColors.background,
        secondary: AppColors.accent,
        onSecondary: AppColors.background,
        surface: AppColors.surface,
        onSurface: AppColors.textPrimary,
        error: Color(0xFFCF6679),
        onError: AppColors.background,
      ),

      // Text theme
      textTheme: _textTheme,

      // App bar theme
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: _textTheme.titleLarge,
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),

      // Icon theme
      iconTheme: const IconThemeData(color: AppColors.textPrimary, size: 24),

      // Button themes
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.glassBackgroundStrong,
          foregroundColor: AppColors.textPrimary,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppColors.glassBorder, width: 1),
          ),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        ),
      ),

      // Card theme
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.glassBorder, width: 1),
        ),
      ),

      // Divider theme
      dividerTheme: const DividerThemeData(
        color: AppColors.glassBorder,
        thickness: 1,
        space: 1,
      ),
    );
  }
}
