import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flick/core/theme/app_colors.dart';

class WaveformSeekBar extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onChanged;
  final ValueChanged<Duration>? onChangeEnd;

  const WaveformSeekBar({
    super.key,
    required this.position,
    required this.duration,
    required this.onChanged,
    this.onChangeEnd,
    this.barCount = 60,
  });

  final int barCount;

  @override
  State<WaveformSeekBar> createState() => _WaveformSeekBarState();
}

class _WaveformSeekBarState extends State<WaveformSeekBar> {
  // Cache the waveform data so it doesn't jitter on rebuilds
  late List<double> _waveformData;
  Duration? _dragStartDuration;
  double? _dragStartX;

  @override
  void initState() {
    super.initState();
    _generateWaveform();
  }

  @override
  void didUpdateWidget(WaveformSeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.duration != oldWidget.duration &&
        widget.duration.inMilliseconds > 0) {
      _generateWaveform();
    }
  }

  void _generateWaveform() {
    // Generate pseudo-random bar heights based on duration to be deterministic for the same song
    final random = Random(widget.duration.inMilliseconds);
    _waveformData = List.generate(
      widget.barCount,
      (index) => 0.3 + random.nextDouble() * 0.7,
    );
  }

  void _onDragStart(DragStartDetails details) {
    _dragStartDuration = widget.position;
    _dragStartX = details.localPosition.dx;
  }

  void _onDragUpdate(DragUpdateDetails details, BoxConstraints constraints) {
    if (_dragStartDuration == null || _dragStartX == null) return;

    final width = constraints.maxWidth;
    final deltaX = details.localPosition.dx - _dragStartX!;
    final progressDelta = deltaX / width;

    // Inversed dragging for scrolling effect
    final newMs =
        _dragStartDuration!.inMilliseconds -
        (progressDelta * widget.duration.inMilliseconds);

    final clampedMs = newMs.clamp(0, widget.duration.inMilliseconds).round();
    widget.onChanged(Duration(milliseconds: clampedMs));
  }

  void _onDragEnd(DragEndDetails details) {
    if (widget.onChangeEnd != null) {
      widget.onChangeEnd!(widget.position);
    }
    _dragStartDuration = null;
    _dragStartX = null;
  }

  void _onTapUp(TapUpDetails details, BoxConstraints constraints) {
    final width = constraints.maxWidth;
    final progress = (details.localPosition.dx / width).clamp(0.0, 1.0);
    final ms = (progress * widget.duration.inMilliseconds).round();
    final newPos = Duration(milliseconds: ms);
    widget.onChanged(newPos);
    widget.onChangeEnd?.call(newPos);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          onHorizontalDragStart: _onDragStart,
          onHorizontalDragUpdate: (details) =>
              _onDragUpdate(details, constraints),
          onHorizontalDragEnd: _onDragEnd,
          onTapUp: (details) => _onTapUp(details, constraints),
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            height: 120, // Increased height
            width: double.infinity,
            child: CustomPaint(
              painter: _WaveformPainter(
                waveformData: _waveformData,
                position: widget.position,
                duration: widget.duration,
                color: AppColors.textTertiary.withValues(alpha: 0.3),
                activeColor: AppColors.accent,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final List<double> waveformData;
  final Duration position;
  final Duration duration;
  final Color color;
  final Color activeColor;

  _WaveformPainter({
    required this.waveformData,
    required this.position,
    required this.duration,
    required this.color,
    required this.activeColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final barCount = waveformData.length;
    // Spacing between bars
    final spacing = 2.0;
    // Calculate total available width for bars (width - total spacing)
    final totalSpacing = (barCount - 1) * spacing;
    final barWidth = (size.width - totalSpacing) / barCount;

    final currentProgress = duration.inMilliseconds == 0
        ? 0.0
        : position.inMilliseconds / duration.inMilliseconds;

    final paint = Paint()..strokeCap = StrokeCap.round;

    // Number of bars for the smooth transition zone
    const transitionBars = 3.0;
    final transitionWidth = transitionBars / barCount;

    for (int i = 0; i < barCount; i++) {
      final barHeight = waveformData[i] * size.height;
      final x = i * (barWidth + spacing) + barWidth / 2;
      final yCenter = size.height / 2;

      // Calculate bar position as progress (0.0 to 1.0)
      final barProgress = i / barCount;

      // Smooth color interpolation around the current progress
      // Calculate how far this bar is from the current progress
      final distanceFromProgress = currentProgress - barProgress;

      Color barColor;
      if (distanceFromProgress >= transitionWidth) {
        // Fully played
        barColor = activeColor;
      } else if (distanceFromProgress <= 0) {
        // Not yet played
        barColor = color;
      } else {
        // In the transition zone - smoothly interpolate
        final t = distanceFromProgress / transitionWidth;
        barColor = Color.lerp(color, activeColor, t)!;
      }

      paint.color = barColor;
      paint.strokeWidth = barWidth;

      // Draw line from center up and down
      canvas.drawLine(
        Offset(x, yCenter - barHeight / 2),
        Offset(x, yCenter + barHeight / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter oldDelegate) {
    // Only repaint if duration changed
    if (oldDelegate.duration != duration) {
      return true;
    }
    
    // For position changes, only repaint if the visual progress (which bar is highlighted) changed
    // Calculate which bar index corresponds to the current progress
    if (duration.inMilliseconds == 0) {
      return false;
    }
    
    final oldProgress = oldDelegate.position.inMilliseconds / oldDelegate.duration.inMilliseconds;
    final newProgress = position.inMilliseconds / duration.inMilliseconds;
    
    // Calculate bar indices (0 to barCount-1)
    final barCount = waveformData.length;
    final oldBarIndex = (oldProgress * barCount).floor();
    final newBarIndex = (newProgress * barCount).floor();
    
    // Only repaint if we've crossed a bar boundary or if the difference is significant
    // This reduces repaints from ~60fps to ~10fps for a typical song
    return oldBarIndex != newBarIndex || 
           (oldProgress - newProgress).abs() > (1.0 / barCount);
  }
}
