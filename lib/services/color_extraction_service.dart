import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Service to extract dominant colors from images for adaptive theming.
///
/// Uses palette extraction to determine the primary colors from album art,
/// enabling background-aware color adjustments throughout the app.
class ColorExtractionService {
  ColorExtractionService._();
  static final ColorExtractionService _instance = ColorExtractionService._();
  factory ColorExtractionService() => _instance;

  // Cache extracted colors to avoid recomputation
  final Map<String, Color> _colorCache = {};

  /// Extracts the dominant/average color from an image file.
  ///
  /// Returns null if extraction fails or file doesn't exist.
  Future<Color?> extractDominantColor(String? imagePath) async {
    if (imagePath == null || imagePath.isEmpty) {
      return null;
    }

    // Check cache first
    if (_colorCache.containsKey(imagePath)) {
      return _colorCache[imagePath];
    }

    try {
      final file = File(imagePath);
      if (!await file.exists()) {
        return null;
      }

      final Uint8List bytes = await file.readAsBytes();
      final ui.Codec codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 32, // Sample at low resolution for speed
        targetHeight: 32,
      );
      final ui.FrameInfo frameInfo = await codec.getNextFrame();
      final ui.Image image = frameInfo.image;

      // Get pixel data
      final ByteData? byteData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );

      if (byteData == null) {
        return null;
      }

      final color = _calculateAverageColor(byteData, image.width, image.height);

      // Cache the result
      _colorCache[imagePath] = color;

      return color;
    } catch (e) {
      debugPrint('ColorExtractionService: Failed to extract color: $e');
      return null;
    }
  }

  /// Calculates the average color from pixel data, with brightness adjustment.
  Color _calculateAverageColor(ByteData byteData, int width, int height) {
    int totalR = 0, totalG = 0, totalB = 0;
    int pixelCount = width * height;

    for (int i = 0; i < byteData.lengthInBytes; i += 4) {
      final r = byteData.getUint8(i);
      final g = byteData.getUint8(i + 1);
      final b = byteData.getUint8(i + 2);
      // Skip alpha (i + 3)

      totalR += r;
      totalG += g;
      totalB += b;
    }

    final avgR = totalR ~/ pixelCount;
    final avgG = totalG ~/ pixelCount;
    final avgB = totalB ~/ pixelCount;

    return Color.fromARGB(255, avgR, avgG, avgB);
  }

  /// Extracts the dominant color and returns it blended with the app's
  /// base background color for a more cohesive look.
  Future<Color> extractBlendedBackgroundColor(
    String? imagePath, {
    Color baseColor = const Color(0xFF0A0A0A),
    double blendFactor = 0.4,
  }) async {
    final dominantColor = await extractDominantColor(imagePath);

    if (dominantColor == null) {
      return baseColor;
    }

    // Blend the dominant color with the base color
    return Color.lerp(baseColor, dominantColor, blendFactor)!;
  }

  /// Clears the color cache. Useful when album art changes.
  void clearCache() {
    _colorCache.clear();
  }

  /// Removes a specific entry from the cache.
  void invalidateCache(String imagePath) {
    _colorCache.remove(imagePath);
  }
}
