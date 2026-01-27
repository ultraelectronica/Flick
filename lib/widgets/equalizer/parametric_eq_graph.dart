import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/providers/equalizer_provider.dart';

class ParametricEqGraph extends ConsumerWidget {
  const ParametricEqGraph({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // We intentionally do NOT watch the whole EQ state here, to avoid wide rebuilds.
    // Painting is driven by the repaint controller, and the painter reads the latest
    // bands from Riverpod when it repaints.
    final repaint = ref.watch(eqGraphRepaintControllerProvider);

    return RepaintBoundary(
      child: CustomPaint(
        painter: _ParametricEqGraphPainter(
          context: context,
          ref: ref,
          repaint: repaint,
        ),
      ),
    );
  }
}

class _ParametricEqGraphPainter extends CustomPainter {
  final BuildContext context;
  final WidgetRef ref;

  _ParametricEqGraphPainter({
    required this.context,
    required this.ref,
    required Listenable repaint,
  }) : super(repaint: repaint);

  static const double _minHz = 20.0;
  static const double _maxHz = 20000.0;

  static const double _minDb = -12.0;
  static const double _maxDb = 12.0;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(1),
      const Radius.circular(AppConstants.radiusMd),
    );

    // Background overlay to help legibility inside glass cards.
    final bgPaint = Paint()
      ..color = AppColors.glassBackgroundStrong.withValues(alpha: 0.10)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(rrect, bgPaint);

    _drawGrid(canvas, size);
    _drawCurve(canvas, size);
  }

  void _drawGrid(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = AppColors.glassBorder.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    // Outer border
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        (Offset.zero & size).deflate(0.5),
        const Radius.circular(AppConstants.radiusMd),
      ),
      gridPaint,
    );

    // Horizontal dB lines
    final dbLines = <double>[-12, -6, 0, 6, 12];
    for (final db in dbLines) {
      final y = _dbToY(db, size.height);
      final paint = Paint()
        ..color = db == 0
            ? AppColors.glassBorderStrong.withValues(alpha: 0.8)
            : AppColors.glassBorder.withValues(alpha: 0.35)
        ..strokeWidth = db == 0 ? 1.2 : 1.0;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }

    // Vertical log-frequency lines (20, 50, 100, 200, 500, 1k, 2k, 5k, 10k, 20k)
    const freqs = <double>[
      20,
      50,
      100,
      200,
      500,
      1000,
      2000,
      5000,
      10000,
      20000,
    ];
    for (final hz in freqs) {
      final x = _hzToX(hz, size.width);
      final paint = Paint()
        ..color = AppColors.glassBorder.withValues(alpha: 0.25)
        ..strokeWidth = 1.0;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  void _drawCurve(Canvas canvas, Size size) {
    final enabled = ref.read(eqEnabledProvider);
    final bands = List<ParametricBand>.generate(
      EqualizerState.defaultParametricFrequenciesHz.length,
      (i) => ref.read(eqParamBandProvider(i)),
      growable: false,
    );

    // If EQ disabled, show a subtle flat line.
    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = enabled
          ? AdaptiveColorProvider.textPrimary(context).withValues(alpha: 0.90)
          : AdaptiveColorProvider.textTertiary(context).withValues(alpha: 0.70);

    final glowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = enabled
          ? AdaptiveColorProvider.textPrimary(context).withValues(alpha: 0.12)
          : AdaptiveColorProvider.textTertiary(context).withValues(alpha: 0.08)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);

    final path = Path();
    final sampleCount = math.max(64, size.width.floor());

    for (var i = 0; i <= sampleCount; i++) {
      final t = i / sampleCount;
      final hz = _tToHz(t);
      final db = enabled ? _approxResponseDb(hz, bands) : 0.0;
      final x = t * size.width;
      final y = _dbToY(db, size.height);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    // Draw glow then stroke for crispness
    canvas.drawPath(path, glowPaint);
    canvas.drawPath(path, strokePaint);

    // Draw control points (band centers)
    final pointPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = enabled
          ? AdaptiveColorProvider.textPrimary(context).withValues(alpha: 0.75)
          : AdaptiveColorProvider.textTertiary(context).withValues(alpha: 0.55);

    for (final band in bands) {
      if (!band.enabled) continue;
      final x = _hzToX(band.frequencyHz, size.width);
      final y = _dbToY(enabled ? band.gainDb : 0.0, size.height);
      canvas.drawCircle(Offset(x, y), 3.0, pointPaint);
    }
  }

  /// UI-only smooth approximation:
  /// Sum of gaussian bumps in log-frequency space, scaled by gain.
  /// Q controls width (higher Q => narrower).
  double _approxResponseDb(double hz, List<ParametricBand> bands) {
    final logHz = math.log(hz);
    double sum = 0.0;

    for (final b in bands) {
      if (!b.enabled) continue;
      // Width in log-space: map Q roughly into sigma.
      final sigma = (0.55 / b.q.clamp(0.2, 10.0)).clamp(0.04, 1.2);
      final d = (logHz - math.log(b.frequencyHz)).abs();
      final w = math.exp(-(d * d) / (2 * sigma * sigma));
      sum += b.gainDb * w;
    }

    return sum.clamp(_minDb, _maxDb).toDouble();
  }

  double _dbToY(double db, double height) {
    final t = ((db - _minDb) / (_maxDb - _minDb)).clamp(0.0, 1.0);
    return height * (1.0 - t);
  }

  double _hzToX(double hz, double width) {
    final t = (_hzToT(hz)).clamp(0.0, 1.0);
    return t * width;
  }

  double _hzToT(double hz) {
    final clamped = hz.clamp(_minHz, _maxHz).toDouble();
    final logMin = math.log(_minHz);
    final logMax = math.log(_maxHz);
    return (math.log(clamped) - logMin) / (logMax - logMin);
  }

  double _tToHz(double t) {
    final logMin = math.log(_minHz);
    final logMax = math.log(_maxHz);
    final v = logMin + (logMax - logMin) * t.clamp(0.0, 1.0);
    return math.exp(v);
  }

  @override
  bool shouldRepaint(covariant _ParametricEqGraphPainter oldDelegate) {
    // Repaint is driven by [repaint] listenable.
    return false;
  }
}
