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
  static const double orbitRadiusRatio =
      0.65; // Ratio of screen width for orbit radius
  static const double orbitCenterOffsetRatio =
      -0.3; // How far off-screen the orbit center is
  static const int orbitVisibleItems = 7; // Number of visible items in orbit
  static const double orbitItemSpacing = 0.18; // Radians between items
  static const double orbitSelectedScale = 1.0; // Scale of selected item
  static const double orbitAdjacentScale = 0.85; // Scale of adjacent items
  static const double orbitDistantScale = 0.65; // Scale of distant items

  // Navigation bar
  static const double navBarHeight = 80.0;
  static const double navBarIconSize = 28.0;
  static const double navBarBottomPadding = 20.0;

  // Song card
  static const double songCardArtSize = 64.0;
  static const double songCardArtSizeLarge = 100.0;
}
