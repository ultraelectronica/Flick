/// App-wide constants for Flick Player.
class AppConstants {
  AppConstants._();

  // Animation durations
  static const Duration animationFast = Duration(milliseconds: 150);
  static const Duration animationNormal = Duration(milliseconds: 300);
  static const Duration animationSlow = Duration(milliseconds: 500);
  static const Duration animationVerySlow = Duration(milliseconds: 800);

  // Spacing values
  static const double spacingXxs = 4.0;
  static const double spacingXs = 8.0;
  static const double spacingSm = 12.0;
  static const double spacingMd = 16.0;
  static const double spacingLg = 24.0;
  static const double spacingXl = 32.0;
  static const double spacingXxl = 48.0;

  // Border radius values
  static const double radiusXs = 4.0;
  static const double radiusSm = 8.0;
  static const double radiusMd = 12.0;
  static const double radiusLg = 16.0;
  static const double radiusXl = 24.0;
  static const double radiusRound = 100.0;

  // Glassmorphism settings
  static const double glassBlurSigma = 15.0;
  static const double glassBlurSigmaLight = 10.0;
  static const double glassBlurSigmaStrong = 20.0;

  // Orbit scroll settings
  static const double orbitRadiusRatio = 1.0; // Large radius for gentle arc
  static const double orbitCenterOffsetRatio = -0.5; // Center off-screen left
  static const int orbitVisibleItems = 9; // More items visible
  static const double orbitItemSpacing = 0.25; // Closer spacing for large arc
  static const double orbitSelectedScale = 1.1;
  static const double orbitAdjacentScale = 0.85;
  static const double orbitDistantScale = 0.6;

  // Navigation bar
  static const double navBarHeight = 80.0;
  static const double navBarIconSize = 28.0;
  static const double navBarBottomPadding = 20.0;

  // Song card
  static const double songCardArtSize = 64.0;
  static const double songCardArtSizeLarge = 100.0;
}
