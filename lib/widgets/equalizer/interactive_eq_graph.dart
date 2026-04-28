import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/providers/equalizer_provider.dart';
import 'package:flick/widgets/equalizer/eq_graph_utils.dart' as equtils;

class InteractiveEqGraphScreen extends ConsumerStatefulWidget {
  final EqMode mode;

  const InteractiveEqGraphScreen({super.key, required this.mode});

  @override
  ConsumerState<InteractiveEqGraphScreen> createState() =>
      _InteractiveEqGraphScreenState();
}

class _InteractiveEqGraphScreenState
    extends ConsumerState<InteractiveEqGraphScreen> {
  int? _draggedHandleIndex;
  int? _qAdjustHandleIndex;
  int? _hoveredHandleIndex;
  final Map<int, Offset> _activePointers = {};
  double _qPointerStartDist = 0.0;
  double _qStartValue = 1.0;

  // Hit-test radius for handles in logical pixels.
  static const double _handleHitRadius = 32.0;
  static const double _handleRadius = 8.0;

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(eqEnabledProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppConstants.spacingMd,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final size = Size(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );
                    return Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (event) => _onPointerDown(event, size),
                      onPointerMove: (event) => _onPointerMoveOrHover(event, size),
                      onPointerUp: _onPointerUp,
                      onPointerCancel: _onPointerUp,
                      child: Stack(
                        children: [
                          CustomPaint(
                            size: size,
                            painter: _EqCurvePainter(
                              mode: widget.mode,
                              enabled: enabled,
                              state: ref.read(equalizerProvider),
                              selectedHandleIndex: _draggedHandleIndex ??
                                  _qAdjustHandleIndex ?? _hoveredHandleIndex,
                              handleRadius: _handleRadius,
                              textScale: MediaQuery.textScalerOf(context).scale(1),
                            ),
                          ),
                          if (_draggedHandleIndex != null ||
                              _qAdjustHandleIndex != null)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: AppConstants.spacingLg,
                              child: _buildGestureHint(),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            if (_draggedHandleIndex != null ||
                _qAdjustHandleIndex != null ||
                _hoveredHandleIndex != null)
              _buildDetailPanel(),
            _buildStatusBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(AppConstants.spacingMd),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(LucideIcons.x),
            color: context.adaptiveTextPrimary,
          ),
          const SizedBox(width: AppConstants.spacingSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Interactive EQ',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: context.adaptiveTextPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  widget.mode == EqMode.graphic
                      ? 'Drag bands up or down'
                      : 'Drag to move • Pinch to widen/narrow',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.adaptiveTextTertiary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGestureHint() {
    final isQ = _qAdjustHandleIndex != null;
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppConstants.spacingMd,
          vertical: AppConstants.spacingSm,
        ),
        decoration: BoxDecoration(
          color: AppColors.background.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(AppConstants.radiusRound),
          border: Border.all(color: AppColors.glassBorderStrong.withValues(alpha: 0.5)),
        ),
        child: Text(
          isQ
              ? 'Pinch apart = narrower (higher Q)\nPinch together = wider (lower Q)'
              : widget.mode == EqMode.graphic
              ? 'Drag vertically to change gain'
              : 'Drag to change frequency & gain',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: context.adaptiveTextPrimary.withValues(alpha: 0.85),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildDetailPanel() {
    final index = _draggedHandleIndex ?? _qAdjustHandleIndex ?? _hoveredHandleIndex;
    if (index == null) return const SizedBox.shrink();

    if (widget.mode == EqMode.graphic) {
      final freq = EqualizerState.defaultGraphicFrequenciesHz[index];
      final gain = ref.read(eqGraphicGainDbProvider(index));
      final bandFamily = _getBandFamily(freq);

      return Container(
        padding: const EdgeInsets.all(AppConstants.spacingMd),
        margin: const EdgeInsets.only(
          left: AppConstants.spacingMd,
          right: AppConstants.spacingMd,
          bottom: AppConstants.spacingLg,
        ),
        decoration: BoxDecoration(
          color: AppColors.background.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(AppConstants.radiusLg),
          border: Border.all(color: AppColors.glassBorderStrong.withValues(alpha: 0.6)),
          boxShadow: [
            BoxShadow(
              color: AppColors.background.withValues(alpha: 0.5),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _DetailItem(
                  label: 'Frequency',
                  value: equtils.hzLabel(freq),
                ),
                _DetailItem(
                  label: 'Band',
                  value: bandFamily,
                ),
                _DetailItem(
                  label: 'Gain',
                  value:
                      '${gain >= 0 ? '+' : ''}${gain.toStringAsFixed(1)} dB',
                ),
              ],
            ),
          ],
        ),
      );
    } else {
      final band = ref.watch(eqParamBandProvider(index));
      if (!band.enabled) return const SizedBox.shrink();

      return Container(
        padding: const EdgeInsets.all(AppConstants.spacingMd),
        margin: const EdgeInsets.only(
          left: AppConstants.spacingMd,
          right: AppConstants.spacingMd,
          bottom: AppConstants.spacingLg,
        ),
        decoration: BoxDecoration(
          color: AppColors.background.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(AppConstants.radiusLg),
          border: Border.all(color: AppColors.glassBorderStrong.withValues(alpha: 0.6)),
          boxShadow: [
            BoxShadow(
              color: AppColors.background.withValues(alpha: 0.5),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _DetailItem(
                  label: 'Frequency',
                  value: equtils.hzLabel(band.frequencyHz),
                ),
                if (band.type.supportsGain)
                  _DetailItem(
                    label: 'Gain',
                    value:
                        '${band.gainDb >= 0 ? '+' : ''}${band.gainDb.toStringAsFixed(1)} dB',
                  ),
                _DetailItem(
                  label: band.type.qLabel,
                  value: band.q.toStringAsFixed(2),
                ),
              ],
            ),
          ],
        ),
      );
    }
  }

  String _getBandFamily(double freqHz) {
    if (freqHz < 60) return 'Sub';
    if (freqHz < 250) return 'Bass';
    if (freqHz < 2000) return 'Mid';
    if (freqHz < 6000) return 'Presence';
    return 'Air';
  }

  Widget _buildStatusBar() {
    final state = ref.watch(equalizerProvider);
    final presetName = state.activePresetName;
    final isEnabled = state.enabled;

    String summaryText;
    if (widget.mode == EqMode.graphic) {
      final adjustedCount = state.graphicGainsDb.where((g) => g.abs() > 0.05).length;
      summaryText = adjustedCount == 0 ? 'Flat' : '$adjustedCount/${state.graphicGainsDb.length} bands adjusted';
    } else {
      final activeCount = state.parametricBands.where((b) => b.enabled).length;
      summaryText = '$activeCount/${state.parametricBands.length} bands active';
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppConstants.spacingMd,
        vertical: AppConstants.spacingSm,
      ),
      margin: const EdgeInsets.only(
        left: AppConstants.spacingMd,
        right: AppConstants.spacingMd,
        bottom: AppConstants.spacingMd,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: Border.all(color: AppColors.glassBorderStrong.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          // Mode chip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.glassBackgroundStrong.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(AppConstants.radiusRound),
            ),
            child: Text(
              widget.mode == EqMode.graphic ? 'Graphic' : 'Parametric',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: context.adaptiveTextPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 10,
              ),
            ),
          ),
          const SizedBox(width: AppConstants.spacingSm),
          // Preset name or summary
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (presetName != null)
                  Text(
                    presetName,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: context.adaptiveTextSecondary,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                Text(
                  summaryText,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: context.adaptiveTextTertiary,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
          // Enabled indicator
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: isEnabled ? AppColors.textPrimary : AppColors.inactiveState,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                isEnabled ? 'ON' : 'OFF',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: isEnabled ? context.adaptiveTextPrimary : context.adaptiveTextTertiary,
                  fontWeight: FontWeight.w700,
                  fontSize: 10,
                ),
              ),
            ],
          ),
          const SizedBox(width: AppConstants.spacingSm),
          // Preamp
          if (state.preampDb.abs() > 0.01)
            Text(
              '${state.preampDb >= 0 ? '+' : ''}${state.preampDb.toStringAsFixed(1)} dB',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: context.adaptiveTextSecondary,
                fontWeight: FontWeight.w600,
                fontSize: 10,
              ),
            ),
        ],
      ),
    );
  }

  // ==========================================================================
  // Pointer handling
  // ==========================================================================

  void _onPointerDown(PointerDownEvent event, Size size) {
    _activePointers[event.pointer] = event.localPosition;

    // If this is the second pointer and we already have a dragged handle,
    // switch to Q adjustment.
    if (_activePointers.length == 2 && _draggedHandleIndex != null) {
      _qAdjustHandleIndex = _draggedHandleIndex;
      _draggedHandleIndex = null;
      _computeQStartDist(size);
      return;
    }

    if (_activePointers.length != 1) return;

    final index = _hitTestHandle(event.localPosition, size);
    if (index != null) {
      _draggedHandleIndex = index;
      _hoveredHandleIndex = null;
      setState(() {});
    }
  }

  void _onPointerHover(PointerMoveEvent event, Size size) {
    if (_activePointers.isNotEmpty) return;

    final index = _hitTestHandle(event.localPosition, size);
    if (index != _hoveredHandleIndex) {
      _hoveredHandleIndex = index;
      setState(() {});
    }
  }

  void _onPointerMoveOrHover(PointerMoveEvent event, Size size) {
    _activePointers[event.pointer] = event.localPosition;

    // Handle hover when not dragging
    if (_activePointers.length == 1 && _draggedHandleIndex == null && _qAdjustHandleIndex == null) {
      _onPointerHover(event, size);
      return;
    }

    if (_activePointers.length == 2 && _qAdjustHandleIndex != null) {
      _updateQFromPinch(size);
      return;
    }

    if (_draggedHandleIndex == null) return;

    final index = _draggedHandleIndex!;
    final position = event.localPosition;

    if (widget.mode == EqMode.graphic) {
      _updateGraphicGain(index, position, size);
    } else {
      _updateParametricBand(index, position, size);
    }
  }

  void _onPointerUp(PointerEvent event) {
    _activePointers.remove(event.pointer);

    if (_activePointers.length < 2) {
      _qAdjustHandleIndex = null;
    }

    if (_activePointers.isEmpty) {
      _draggedHandleIndex = null;
      _hoveredHandleIndex = null;
    }

    setState(() {});
  }

  // ==========================================================================
  // Hit testing
  // ==========================================================================

  int? _hitTestHandle(Offset position, Size size) {
    if (widget.mode == EqMode.graphic) {
      final freqs = EqualizerState.defaultGraphicFrequenciesHz;
      final gains = List<double>.generate(
        freqs.length,
        (i) => ref.read(eqGraphicGainDbProvider(i)),
        growable: false,
      );

      for (var i = 0; i < freqs.length; i++) {
        final center = _dataToPixel(
          equtils.hzToX(freqs[i]),
          gains[i],
          size,
        );
        if ((position - center).distance <= _handleHitRadius) {
          return i;
        }
      }
    } else {
      final bands = ref.read(equalizerProvider).parametricBands;
      for (var i = 0; i < bands.length; i++) {
        if (!bands[i].enabled) continue;
        final db = parametricResponseDbAtHz(
          hz: bands[i].frequencyHz,
          bands: bands,
        );
        final center = _dataToPixel(
          equtils.hzToX(bands[i].frequencyHz),
          db,
          size,
        );
        if ((position - center).distance <= _handleHitRadius) {
          return i;
        }
      }
    }
    return null;
  }

  // ==========================================================================
  // Data <-> Pixel conversions
  // ==========================================================================

  static const double _paddingTop = 24.0;
  static const double _paddingBottom = 40.0;
  static const double _paddingLeft = 16.0;
  static const double _paddingRight = 16.0;

  Offset _dataToPixel(double logX, double db, Size size) {
    final plotW = size.width - _paddingLeft - _paddingRight;
    final plotH = size.height - _paddingTop - _paddingBottom;
    final tX = (logX - equtils.eqLogMin) /
        (equtils.eqLogMax - equtils.eqLogMin);
    final tY = 1.0 -
        (db - equtils.eqMinDb) /
            (equtils.eqMaxDb - equtils.eqMinDb);
    return Offset(
      _paddingLeft + tX.clamp(0.0, 1.0) * plotW,
      _paddingTop + tY.clamp(0.0, 1.0) * plotH,
    );
  }

  ({double logX, double db}) _pixelToData(Offset pixel, Size size) {
    final plotW = size.width - _paddingLeft - _paddingRight;
    final plotH = size.height - _paddingTop - _paddingBottom;
    final tX = ((pixel.dx - _paddingLeft) / plotW).clamp(0.0, 1.0);
    final tY = ((pixel.dy - _paddingTop) / plotH).clamp(0.0, 1.0);
    final logX = equtils.eqLogMin +
        tX * (equtils.eqLogMax - equtils.eqLogMin);
    final db = equtils.eqMaxDb -
        tY * (equtils.eqMaxDb - equtils.eqMinDb);
    return (logX: logX, db: db);
  }

  // ==========================================================================
  // Update logic
  // ==========================================================================

  void _updateGraphicGain(int index, Offset position, Size size) {
    final data = _pixelToData(position, size);
    ref
        .read(equalizerProvider.notifier)
        .setGraphicGainDb(index, data.db);
  }

  void _updateParametricBand(int index, Offset position, Size size) {
    final data = _pixelToData(position, size);
    final hz = equtils.xToHz(data.logX);
    ref
        .read(equalizerProvider.notifier)
        .setParamBandFreqHz(index, hz);
    final band = ref.read(eqParamBandProvider(index));
    if (band.type.supportsGain) {
      ref
          .read(equalizerProvider.notifier)
          .setParamBandGainDb(index, data.db);
    }
  }

  void _computeQStartDist(Size size) {
    final pointers = _activePointers.values.toList();
    if (pointers.length < 2) return;
    _qPointerStartDist = (pointers[0] - pointers[1]).distance;
    if (_qAdjustHandleIndex != null) {
      _qStartValue =
          ref.read(eqParamBandProvider(_qAdjustHandleIndex!)).q;
    }
  }

  void _updateQFromPinch(Size size) {
    final pointers = _activePointers.values.toList();
    if (pointers.length < 2 || _qAdjustHandleIndex == null) return;

    final currentDist = (pointers[0] - pointers[1]).distance;
    if (_qPointerStartDist < 4.0) return; // avoid division by near-zero

    final scale = currentDist / _qPointerStartDist;
    final newQ = (_qStartValue * scale).clamp(0.2, 10.0);
    ref
        .read(equalizerProvider.notifier)
        .setParamBandQ(_qAdjustHandleIndex!, newQ);
  }
}

// =============================================================================
// Detail item widget
// =============================================================================

class _DetailItem extends StatelessWidget {
  final String label;
  final String value;

  const _DetailItem({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: context.adaptiveTextTertiary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: context.adaptiveTextPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Custom painter
// =============================================================================

class _EqCurvePainter extends CustomPainter {
  final EqMode mode;
  final bool enabled;
  final EqualizerState state;
  final int? selectedHandleIndex;
  final double handleRadius;
  final double textScale;

  _EqCurvePainter({
    required this.mode,
    required this.enabled,
    required this.state,
    required this.selectedHandleIndex,
    required this.handleRadius,
    required this.textScale,
  });

  static const double _paddingTop = 24.0;
  static const double _paddingBottom = 40.0;
  static const double _paddingLeft = 16.0;
  static const double _paddingRight = 16.0;

  @override
  void paint(Canvas canvas, Size size) {
    final plotW = size.width - _paddingLeft - _paddingRight;
    final plotH = size.height - _paddingTop - _paddingBottom;
    final plotRect = Rect.fromLTWH(
      _paddingLeft,
      _paddingTop,
      plotW,
      plotH,
    );

    final lineColor = enabled
        ? AppColors.textPrimary.withValues(alpha: 0.90)
        : AppColors.textTertiary.withValues(alpha: 0.70);

    _drawGrid(canvas, plotRect, lineColor);

    if (mode == EqMode.graphic) {
      _drawGraphicCurve(canvas, plotRect, lineColor);
      _drawGraphicHandles(canvas, plotRect, lineColor);
    } else {
      _drawParametricCurve(canvas, plotRect, lineColor);
      _drawParametricHandles(canvas, plotRect, lineColor);
    }
  }

  void _drawGrid(Canvas canvas, Rect plotRect, Color lineColor) {
    final gridPaint = Paint()
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    // Horizontal lines (dB)
    for (double db = equtils.eqMinDb; db <= equtils.eqMaxDb; db += 3.0) {
      final isZero = db.abs() < 0.001;
      final tY = 1.0 -
          (db - equtils.eqMinDb) /
              (equtils.eqMaxDb - equtils.eqMinDb);
      final y = plotRect.top + tY.clamp(0.0, 1.0) * plotRect.height;

      gridPaint.color = (isZero ? AppColors.glassBorderStrong : AppColors.glassBorder)
          .withValues(alpha: isZero ? 0.8 : 0.35);
      if (isZero) gridPaint.strokeWidth = 1.2;

      canvas.drawLine(
        Offset(plotRect.left, y),
        Offset(plotRect.right, y),
        gridPaint,
      );
      gridPaint.strokeWidth = 1.0;

      // dB label
      final label = isZero ? '0 dB' : '${db >= 0 ? '+' : ''}${db.toStringAsFixed(0)}';
      final textPainter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            fontFamily: 'ProductSans',
            fontSize: 9 * textScale,
            color: AppColors.textTertiary.withValues(alpha: 0.7),
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(plotRect.left + 4, y - textPainter.height - 2),
      );
    }

    // Vertical lines (freqs)
    const guideFreqs = <double>[
      20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000,
    ];
    for (final hz in guideFreqs) {
      final tX = (equtils.hzToX(hz) - equtils.eqLogMin) /
          (equtils.eqLogMax - equtils.eqLogMin);
      final x = plotRect.left + tX.clamp(0.0, 1.0) * plotRect.width;

      gridPaint.color = AppColors.glassBorder.withValues(alpha: 0.25);
      canvas.drawLine(
        Offset(x, plotRect.top),
        Offset(x, plotRect.bottom),
        gridPaint,
      );

      // Freq label
      final label = equtils.hzLabel(hz);
      final textPainter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            fontFamily: 'ProductSans',
            fontSize: 9 * textScale,
            color: AppColors.textTertiary.withValues(alpha: 0.7),
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(x - textPainter.width / 2, plotRect.bottom + 4),
      );
    }
  }

  void _drawGraphicCurve(Canvas canvas, Rect plotRect, Color lineColor) {
    final freqs = EqualizerState.defaultGraphicFrequenciesHz;
    final gains = state.graphicGainsDb;
    final points = equtils.buildGraphicCurvePoints(
      enabled: enabled,
      freqs: freqs,
      gains: gains,
      sampleCount: math.max(96, plotRect.width.floor()),
    );
    _drawCurvePath(canvas, plotRect, points, lineColor);
  }

  void _drawParametricCurve(Canvas canvas, Rect plotRect, Color lineColor) {
    final points = equtils.buildParametricCurvePoints(
      enabled: enabled,
      bands: state.parametricBands,
      sampleCount: math.max(96, plotRect.width.floor()),
    );
    _drawCurvePath(canvas, plotRect, points, lineColor);
  }

  void _drawCurvePath(
    Canvas canvas,
    Rect plotRect,
    List<({double x, double db})> points,
    Color lineColor,
  ) {
    if (points.isEmpty) return;

    final path = Path();
    var first = true;
    for (final p in points) {
      final tX = (p.x - equtils.eqLogMin) /
          (equtils.eqLogMax - equtils.eqLogMin);
      final tY = 1.0 -
          (p.db - equtils.eqMinDb) /
              (equtils.eqMaxDb - equtils.eqMinDb);
      final x = plotRect.left + tX.clamp(0.0, 1.0) * plotRect.width;
      final y = plotRect.top + tY.clamp(0.0, 1.0) * plotRect.height;
      if (first) {
        path.moveTo(x, y);
        first = false;
      } else {
        path.lineTo(x, y);
      }
    }

    // Glow
    final glowPaint = Paint()
      ..color = lineColor.withValues(alpha: 0.12)
      ..strokeWidth = 6.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18);
    canvas.drawPath(path, glowPaint);

    // Fill below
    final fillPath = Path.from(path);
    fillPath.lineTo(plotRect.right, plotRect.bottom);
    fillPath.lineTo(plotRect.left, plotRect.bottom);
    fillPath.close();
    final fillPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(plotRect.left, plotRect.top),
        Offset(plotRect.left, plotRect.bottom),
        [
          lineColor.withValues(alpha: 0.08),
          lineColor.withValues(alpha: 0.00),
        ],
      );
    canvas.drawPath(fillPath, fillPaint);

    // Stroke
    final strokePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, strokePaint);
  }

  void _drawGraphicHandles(Canvas canvas, Rect plotRect, Color lineColor) {
    final freqs = EqualizerState.defaultGraphicFrequenciesHz;
    final gains = state.graphicGainsDb;

    for (var i = 0; i < freqs.length; i++) {
      final tX = (equtils.hzToX(freqs[i]) - equtils.eqLogMin) /
          (equtils.eqLogMax - equtils.eqLogMin);
      final tY = 1.0 -
          (gains[i] - equtils.eqMinDb) /
              (equtils.eqMaxDb - equtils.eqMinDb);
      final center = Offset(
        plotRect.left + tX.clamp(0.0, 1.0) * plotRect.width,
        plotRect.top + tY.clamp(0.0, 1.0) * plotRect.height,
      );
      _drawHandle(canvas, center, lineColor, i == selectedHandleIndex);
    }
  }

  void _drawParametricHandles(Canvas canvas, Rect plotRect, Color lineColor) {
    final bands = state.parametricBands;
    for (var i = 0; i < bands.length; i++) {
      if (!bands[i].enabled) continue;
      final db = parametricResponseDbAtHz(
        hz: bands[i].frequencyHz,
        bands: bands,
      );
      final tX = (equtils.hzToX(bands[i].frequencyHz) - equtils.eqLogMin) /
          (equtils.eqLogMax - equtils.eqLogMin);
      final tY = 1.0 -
          (db - equtils.eqMinDb) /
              (equtils.eqMaxDb - equtils.eqMinDb);
      final center = Offset(
        plotRect.left + tX.clamp(0.0, 1.0) * plotRect.width,
        plotRect.top + tY.clamp(0.0, 1.0) * plotRect.height,
      );
      _drawHandle(canvas, center, lineColor, i == selectedHandleIndex);
    }
  }

  void _drawHandle(
    Canvas canvas,
    Offset center,
    Color lineColor,
    bool selected,
  ) {
    if (selected) {
      final ringPaint = Paint()
        ..color = lineColor.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawCircle(center, handleRadius + 6, ringPaint);
    }

    final fillPaint = Paint()
      ..color = lineColor.withValues(alpha: selected ? 1.0 : 0.75);
    canvas.drawCircle(center, handleRadius, fillPaint);

    final innerPaint = Paint()
      ..color = AppColors.background;
    canvas.drawCircle(center, handleRadius * 0.45, innerPaint);
  }

  @override
  bool shouldRepaint(covariant _EqCurvePainter oldDelegate) {
    return oldDelegate.enabled != enabled ||
        oldDelegate.state != state ||
        oldDelegate.selectedHandleIndex != selectedHandleIndex ||
        oldDelegate.mode != mode;
  }
}
