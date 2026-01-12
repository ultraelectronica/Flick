// ignore_for_file: use_build_context_synchronously

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flick/core/theme/app_colors.dart';

/// A cached image widget that handles both file and network images with caching,
/// placeholders, and optional thumbnail support.
class CachedImageWidget extends StatelessWidget {
  /// Image path (file path or network URL)
  final String? imagePath;

  /// BoxFit for the image
  final BoxFit fit;

  /// Placeholder widget to show while loading or on error
  final Widget? placeholder;

  /// Error widget to show if image fails to load
  final Widget? errorWidget;

  /// Optional width constraint
  final double? width;

  /// Optional height constraint
  final double? height;

  /// Whether to use thumbnail (lower resolution) for better performance
  final bool useThumbnail;

  /// Target width for thumbnail (if useThumbnail is true)
  final int? thumbnailWidth;

  /// Target height for thumbnail (if useThumbnail is true)
  final int? thumbnailHeight;

  const CachedImageWidget({
    super.key,
    this.imagePath,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.errorWidget,
    this.width,
    this.height,
    this.useThumbnail = false,
    this.thumbnailWidth,
    this.thumbnailHeight,
  });

  /// Default placeholder widget
  static Widget defaultPlaceholder() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.surfaceLight, AppColors.surface],
        ),
      ),
      child: const Center(
        child: Icon(
          Icons.music_note_rounded,
          color: AppColors.textTertiary,
          size: 28,
        ),
      ),
    );
  }

  /// Default error widget
  static Widget defaultErrorWidget() {
    return defaultPlaceholder();
  }

  @override
  Widget build(BuildContext context) {
    if (imagePath == null || imagePath!.isEmpty) {
      return SizedBox(
        width: width,
        height: height,
        child: errorWidget ?? defaultErrorWidget(),
      );
    }

    // For file paths, use FileImage with caching
    if (!imagePath!.startsWith('http')) {
      return _buildFileImage();
    }

    // For network URLs, use cached network image
    return _buildNetworkImage();
  }

  Widget _buildFileImage() {
    final file = File(imagePath!);

    return FutureBuilder<bool>(
      future: file.exists(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || !snapshot.data!) {
          return SizedBox(
            width: width,
            height: height,
            child: errorWidget ?? defaultErrorWidget(),
          );
        }

        return Image.file(
          file,
          width: width,
          height: height,
          fit: fit,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded || frame != null) {
              return child;
            }
            return SizedBox(
              width: width,
              height: height,
              child: placeholder ?? defaultPlaceholder(),
            );
          },
          errorBuilder: (context, error, stackTrace) {
            return SizedBox(
              width: width,
              height: height,
              child: errorWidget ?? defaultErrorWidget(),
            );
          },
          // Use lower resolution for thumbnails
          cacheWidth: useThumbnail && thumbnailWidth != null
              ? thumbnailWidth
              : null,
          cacheHeight: useThumbnail && thumbnailHeight != null
              ? thumbnailHeight
              : null,
        );
      },
    );
  }

  Widget _buildNetworkImage() {
    return Image.network(
      imagePath!,
      width: width,
      height: height,
      fit: fit,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded || frame != null) {
          return child;
        }
        return SizedBox(
          width: width,
          height: height,
          child: placeholder ?? defaultPlaceholder(),
        );
      },
      errorBuilder: (context, error, stackTrace) {
        return SizedBox(
          width: width,
          height: height,
          child: errorWidget ?? defaultErrorWidget(),
        );
      },
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) {
          return child;
        }
        return SizedBox(
          width: width,
          height: height,
          child: placeholder ?? defaultPlaceholder(),
        );
      },
      // Use lower resolution for thumbnails
      cacheWidth: useThumbnail && thumbnailWidth != null
          ? thumbnailWidth
          : null,
      cacheHeight: useThumbnail && thumbnailHeight != null
          ? thumbnailHeight
          : null,
    );
  }
}

/// Helper class for preloading images
class ImagePreloader {
  static final DefaultCacheManager _cacheManager = DefaultCacheManager();

  static Future<void> preloadFile(
    String filePath,
    BuildContext context, {
    required bool Function() isMounted,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      return;
    }

    // Check if widget is still mounted before using context
    if (!isMounted()) {
      return;
    }

    try {
      // Decode the image to cache it in memory
      final imageProvider = FileImage(file);
      // Check again before precaching (context might be invalid)
      if (isMounted()) {
        await precacheImage(imageProvider, context);
      }
    } catch (e) {
      // Ignore errors during preloading (context might be invalid)
    }
  }

  static Future<void> preloadNetwork(
    String url,
    BuildContext context, {
    required bool Function() isMounted,
  }) async {
    try {
      // First cache the file
      await _cacheManager.getSingleFile(url);

      // Check if widget is still mounted before using context
      if (!isMounted()) {
        return;
      }

      // Then decode it into memory
      final imageProvider = NetworkImage(url);
      // Check again before precaching (context might be invalid)
      if (isMounted()) {
        await precacheImage(imageProvider, context);
      }
    } catch (e) {
      // Ignore errors during preloading (context might be invalid)
    }
  }

  /// Preload multiple images
  ///
  /// [isMounted] callback should return true if the widget is still mounted.
  /// This prevents using BuildContext across async gaps.
  ///
  /// Usage:
  /// ```dart
  /// ImagePreloader.preloadImages(['path1.jpg', 'path2.jpg'], context, isMounted: () => mounted);
  /// ```
  static Future<void> preloadImages(
    List<String> imagePaths,
    BuildContext context, {
    required bool Function() isMounted,
  }) async {
    final futures = imagePaths.map((path) {
      if (path.startsWith('http')) {
        return preloadNetwork(path, context, isMounted: isMounted);
      } else {
        return preloadFile(path, context, isMounted: isMounted);
      }
    });
    await Future.wait(futures);
  }
}
