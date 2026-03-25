import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flick/models/song.dart';

// ---------------------------------------------------------------------------
// AmbientBackground
//
// Strategy: decode + blur the album art **once** per song change using
// dart:ui APIs on the main isolate (async — does not block the UI thread).
// The result is cached as a plain [ui.Image] and displayed with [RawImage].
//
// This eliminates the per-frame GPU cost of BackdropFilter (sigma=25).
// dart:ui APIs MUST run on the main isolate — they cannot be passed to
// compute() because they require Flutter engine bindings.
// ---------------------------------------------------------------------------

class AmbientBackground extends StatefulWidget {
  final Song? song;

  const AmbientBackground({super.key, this.song});

  @override
  State<AmbientBackground> createState() => _AmbientBackgroundState();
}

class _AmbientBackgroundState extends State<AmbientBackground> {
  /// Blur sigma. Lower sigma on the already-downscaled image (~300px wide)
  /// produces the same perceived softness as sigma=25 on a full-res image.
  static const double _blurSigma = 12.0;

  /// Max dimension to decode the source image into (saves memory + decode time).
  static const int _targetDimension = 300;

  ui.Image? _blurredImage;
  String? _currentPath; // path we're building / have built
  bool _computing = false;

  @override
  void initState() {
    super.initState();
    _updateBlur(widget.song?.albumArt);
  }

  @override
  void didUpdateWidget(AmbientBackground old) {
    super.didUpdateWidget(old);
    final newPath = widget.song?.albumArt;
    if (newPath != old.song?.albumArt) {
      _updateBlur(newPath);
    }
  }

  @override
  void dispose() {
    _blurredImage?.dispose();
    super.dispose();
  }

  Future<void> _updateBlur(String? path) async {
    if (path == null) {
      if (mounted) {
        final old = _blurredImage;
        setState(() {
          _blurredImage = null;
          _currentPath = null;
        });
        old?.dispose();
      }
      return;
    }

    // Debounce: already computing for this exact path
    if (_computing && _currentPath == path) return;

    _currentPath = path;
    _computing = true;

    try {
      // 1. Read raw bytes from disk (async IO — does not block UI thread)
      final file = File(path);
      if (!await file.exists()) {
        _computing = false;
        return;
      }
      final bytes = await file.readAsBytes();

      // Bail if widget disposed or song changed while we were reading
      if (!mounted || path != widget.song?.albumArt) {
        _computing = false;
        return;
      }

      // 2. Decode at reduced resolution (codec handles downscale on raster thread)
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: _targetDimension,
        targetHeight: _targetDimension,
      );
      final frame = await codec.getNextFrame();
      final srcImage = frame.image;

      if (!mounted || path != widget.song?.albumArt) {
        srcImage.dispose();
        _computing = false;
        return;
      }

      // 3. Draw with blur ImageFilter into a Picture, then rasterise.
      //    picture.toImage() runs on Flutter's raster thread — non-blocking.
      // Capture dimensions before disposal.
      final int imgW = srcImage.width;
      final int imgH = srcImage.height;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImage(
        srcImage,
        Offset.zero,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: _blurSigma,
            sigmaY: _blurSigma,
            tileMode: TileMode.clamp,
          ),
      );
      final picture = recorder.endRecording();
      srcImage.dispose();

      final blurred = await picture.toImage(imgW, imgH);
      picture.dispose();

      if (!mounted || path != widget.song?.albumArt) {
        blurred.dispose();
        _computing = false;
        return;
      }

      final old = _blurredImage;
      setState(() => _blurredImage = blurred);
      old?.dispose();
    } catch (e) {
      debugPrint('[AmbientBackground] blur failed: $e');
    } finally {
      _computing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.song?.albumArt == null) return const SizedBox.shrink();

    return RepaintBoundary(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 600),
        child: _blurredImage != null
            ? SizedBox.expand(
                key: ValueKey(_currentPath),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Pre-blurred raster — zero GPU filter cost per frame
                    RawImage(
                      image: _blurredImage,
                      fit: BoxFit.cover,
                      opacity: const AlwaysStoppedAnimation(0.6),
                    ),
                    // Dark scrim for readability
                    ColoredBox(
                      color: Colors.black.withValues(alpha: 0.3),
                    ),
                  ],
                ),
              )
            : const SizedBox.expand(key: ValueKey('placeholder')),
      ),
    );
  }
}
