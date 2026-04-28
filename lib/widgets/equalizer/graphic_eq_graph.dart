import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';

import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/providers/equalizer_provider.dart';
import 'package:flick/widgets/equalizer/eq_graph_utils.dart' as equtils;

class GraphicEqGraph extends ConsumerWidget {
  const GraphicEqGraph({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repaint = ref.watch(eqGraphRepaintControllerProvider);

    // Avoid wide rebuilds: we don't watch EQ state here.
    // Instead we rebuild the chart only when the repaint controller bumps.
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: repaint,
        builder: (context, _) {
          final enabled = ref.read(eqEnabledProvider);
          final freqs = EqualizerState.defaultGraphicFrequenciesHz;
          final gains = List<double>.generate(
            freqs.length,
            (i) => ref.read(eqGraphicGainDbProvider(i)),
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

              final curvePoints = equtils.buildGraphicCurvePoints(
                enabled: enabled,
                freqs: freqs,
                gains: gains,
                sampleCount: sampleCount,
              );
              final spots = curvePoints
                  .map((p) => FlSpot(p.x, p.db))
                  .toList(growable: false);

              final dotSpots = enabled
                  ? List<FlSpot>.generate(
                      freqs.length,
                      (i) => FlSpot(equtils.hzToX(freqs[i]), gains[i]),
                      growable: false,
                    )
                  : List<FlSpot>.generate(
                      freqs.length,
                      (i) => FlSpot(equtils.hzToX(freqs[i]), 0.0),
                      growable: false,
                    );

              final contentWidth = math.max(width * 2, 640.0);

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
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    child: SizedBox(
                      width: contentWidth,
                      child: LineChart(
                        LineChartData(
                           minX: equtils.eqLogMin,
                          maxX: equtils.eqLogMax,
                          minY: equtils.eqMinDb,
                          maxY: equtils.eqMaxDb,
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
                                  // Map log10(x) back to labelled frequencies.
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
                                    final gx = equtils.hzToX(hz);
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
                              // We draw only a handful of guide lines at key freqs.
                              // fl_chart calls this for each 'value' step, so we
                              // return transparent for non-guide values.
                              final alpha = equtils.isGuideLogX(value) ? 0.25 : 0.0;
                              return FlLine(
                                color: AppColors.glassBorder.withValues(
                                  alpha: alpha,
                                ),
                                strokeWidth: 1.0,
                              );
                            },
                            checkToShowVerticalLine: equtils.isGuideLogX,
                          ),
                          lineBarsData: [
                            // Glow (thicker, blurred via shadow)
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

// Chart helpers moved to eq_graph_utils.dart
