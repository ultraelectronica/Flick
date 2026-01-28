import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:math' as math;

import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/providers/equalizer_provider.dart';

class ParametricEqGraph extends ConsumerWidget {
  const ParametricEqGraph({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repaint = ref.watch(eqGraphRepaintControllerProvider);

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: repaint,
        builder: (context, _) {
          final enabled = ref.read(eqEnabledProvider);
          final bands = List<ParametricBand>.generate(
            EqualizerState.defaultParametricFrequenciesHz.length,
            (i) => ref.read(eqParamBandProvider(i)),
            growable: false,
          );

          return LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth.isFinite
                  ? constraints.maxWidth
                  : 300.0;
              final sampleCount = math.max(96, width.floor());

              final lineColor = enabled
                  ? AdaptiveColorProvider.textPrimary(
                      context,
                    ).withValues(alpha: 0.90)
                  : AdaptiveColorProvider.textTertiary(
                      context,
                    ).withValues(alpha: 0.70);

              final spots = _buildParametricSpots(
                enabled: enabled,
                bands: bands,
                sampleCount: sampleCount,
              );

              final dotSpots = <FlSpot>[
                for (final b in bands)
                  if (b.enabled)
                    FlSpot(_hzToX(b.frequencyHz), enabled ? b.gainDb : 0.0),
              ];

              return ClipRRect(
                borderRadius: BorderRadius.circular(AppConstants.radiusMd),
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.glassBackgroundStrong.withValues(
                      alpha: 0.10,
                    ),
                    borderRadius: BorderRadius.circular(AppConstants.radiusMd),
                    border: Border.all(
                      color: AppColors.glassBorder.withValues(alpha: 0.5),
                      width: 1,
                    ),
                  ),
                  child: LineChart(
                    LineChartData(
                      minX: _logMin,
                      maxX: _logMax,
                      minY: _minDb,
                      maxY: _maxDb,
                      lineTouchData: const LineTouchData(enabled: false),
                      clipData: const FlClipData.all(),
                      borderData: FlBorderData(show: false),
                      titlesData: FlTitlesData(
                        show: true,
                        topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        leftTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 20,
                            getTitlesWidget: (value, meta) {
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
                              const tol = 0.03; // in log10 units
                              double? matched;
                              for (final hz in freqs) {
                                final gx = _hzToX(hz);
                                if ((value - gx).abs() <= tol) {
                                  matched = hz;
                                  break;
                                }
                              }
                              if (matched == null) {
                                return const SizedBox.shrink();
                              }

                              String label;
                              if (matched >= 1000) {
                                final k = matched / 1000.0;
                                label =
                                    '${k.toStringAsFixed(k >= 10 ? 0 : 1)}k';
                              } else {
                                label = matched.toStringAsFixed(0);
                              }

                              return Padding(
                                padding: const EdgeInsets.only(
                                  top: 2.0,
                                  right: 2.0,
                                ),
                                child: Text(
                                  label,
                                  style: const TextStyle(
                                    fontFamily: 'ProductSans',
                                    fontSize: 9,
                                    color: AppColors.textTertiary,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: true,
                        drawHorizontalLine: true,
                        verticalInterval: 1.0,
                        horizontalInterval: 6.0,
                        getDrawingHorizontalLine: (value) {
                          final isZero = value.abs() < 0.001;
                          return FlLine(
                            color:
                                (isZero
                                        ? AppColors.glassBorderStrong
                                        : AppColors.glassBorder)
                                    .withValues(alpha: isZero ? 0.8 : 0.35),
                            strokeWidth: isZero ? 1.2 : 1.0,
                          );
                        },
                        getDrawingVerticalLine: (value) {
                          final alpha = _isGuideLogX(value) ? 0.25 : 0.0;
                          return FlLine(
                            color: AppColors.glassBorder.withValues(
                              alpha: alpha,
                            ),
                            strokeWidth: 1.0,
                          );
                        },
                        checkToShowVerticalLine: _isGuideLogX,
                      ),
                      lineBarsData: [
                        // Glow + fill (Squiglink-ish)
                        LineChartBarData(
                          spots: spots,
                          isCurved: false,
                          barWidth: 6.0,
                          isStrokeCapRound: true,
                          color: lineColor.withValues(alpha: 0.12),
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(
                            show: true,
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                lineColor.withValues(alpha: 0.08),
                                lineColor.withValues(alpha: 0.00),
                              ],
                            ),
                          ),
                          shadow: Shadow(
                            color: lineColor.withValues(alpha: 0.18),
                            blurRadius: 18,
                          ),
                        ),
                        // Stroke
                        LineChartBarData(
                          spots: spots,
                          isCurved: false,
                          barWidth: 2.0,
                          isStrokeCapRound: true,
                          color: lineColor,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(show: false),
                        ),
                        // Band points
                        LineChartBarData(
                          spots: dotSpots,
                          isCurved: false,
                          barWidth: 0,
                          color: Colors.transparent,
                          belowBarData: BarAreaData(show: false),
                          dotData: FlDotData(
                            show: true,
                            getDotPainter: (spot, percent, barData, index) {
                              return FlDotCirclePainter(
                                radius: 3.0,
                                color: lineColor.withValues(alpha: 0.75),
                                strokeWidth: 0,
                                strokeColor: Colors.transparent,
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ============================================================================
// Chart helpers (log-frequency X, dB Y)
// ============================================================================

const double _minHz = 20.0;
const double _maxHz = 20000.0;
const double _minDb = -12.0;
const double _maxDb = 12.0;

final double _logMin = math.log(_minHz) / math.ln10;
final double _logMax = math.log(_maxHz) / math.ln10;

double _hzToX(double hz) => (math.log(hz.clamp(_minHz, _maxHz)) / math.ln10);

double _tToHz(double t) {
  final logMin = math.log(_minHz);
  final logMax = math.log(_maxHz);
  final v = logMin + (logMax - logMin) * t.clamp(0.0, 1.0);
  return math.exp(v);
}

List<FlSpot> _buildParametricSpots({
  required bool enabled,
  required List<ParametricBand> bands,
  required int sampleCount,
}) {
  final spots = <FlSpot>[];
  for (var i = 0; i <= sampleCount; i++) {
    final t = i / sampleCount;
    final hz = _tToHz(t);
    final db = enabled ? _approxResponseDb(hz, bands) : 0.0;
    spots.add(FlSpot(_hzToX(hz), db));
  }
  return spots;
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

bool _isGuideLogX(double x) {
  const guideFreqs = <double>[
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
  const tol = 0.025; // in log10 units
  for (final hz in guideFreqs) {
    final gx = _hzToX(hz);
    if ((x - gx).abs() <= tol) return true;
  }
  return false;
}
