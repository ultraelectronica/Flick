import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/models/song.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/features/player/widgets/waveform_layer.dart';
import 'package:flick/features/player/widgets/player_controls.dart';

class _PlaybackTimeRow extends StatelessWidget {
  final PlayerService playerService;
  final String Function(Duration) formatDuration;
  final Song? currentSong;
  final double horizontalPadding;

  const _PlaybackTimeRow({
    required this.playerService,
    required this.formatDuration,
    required this.currentSong,
    this.horizontalPadding = 0,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Duration>(
      valueListenable: playerService.positionNotifier,
      builder: (context, position, _) {
        return ValueListenableBuilder<Duration>(
          valueListenable: playerService.durationNotifier,
          builder: (context, engineDuration, _) {
            final duration = engineDuration.inMilliseconds > 0
                ? engineDuration
                : (currentSong?.duration ?? Duration.zero);

            return PlaybackTimeLabels(
              position: position,
              duration: duration,
              formatDuration: formatDuration,
              horizontalPadding: horizontalPadding,
            );
          },
        );
      },
    );
  }
}

class LyricsModeWaveformStrip extends StatefulWidget {
  final PlayerService playerService;
  final ValueNotifier<Duration> positionNotifier;
  final Song? currentSong;
  final String Function(Duration) formatDuration;
  final double horizontalPadding;
  final VoidCallback onSwipeUp;
  final bool showTimeLabels;
  final bool showArrow;

  const LyricsModeWaveformStrip({super.key,
    required this.playerService,
    required this.positionNotifier,
    required this.currentSong,
    required this.formatDuration,
    required this.horizontalPadding,
    required this.onSwipeUp,
    this.showTimeLabels = true,
    this.showArrow = true,
  });

  @override
  State<LyricsModeWaveformStrip> createState() =>
      _LyricsModeWaveformStripState();
}

class _LyricsModeWaveformStripState extends State<LyricsModeWaveformStrip>
    with SingleTickerProviderStateMixin {
  static const Duration _toggleDuration = Duration(milliseconds: 400);
  static const Curve _toggleCurve = Curves.easeInOut;

  Offset? _pointerDownPosition;
  bool _didTriggerSwipe = false;

  late final AnimationController _arrowAnimController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _arrowAnimController.dispose();
    super.dispose();
  }

  void _resetPointerTracking() {
    _pointerDownPosition = null;
    _didTriggerSwipe = false;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    final start = _pointerDownPosition;
    if (start == null || _didTriggerSwipe) {
      return;
    }

    final delta = event.position - start;
    final isSwipeUp = delta.dy <= -28;
    final isPrimarilyVertical = delta.dy.abs() > (delta.dx.abs() * 1.2);

    if (widget.showArrow && isSwipeUp && isPrimarilyVertical) {
      _didTriggerSwipe = true;
      widget.onSwipeUp();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        _pointerDownPosition = event.position;
        _didTriggerSwipe = false;
      },
      onPointerMove: _handlePointerMove,
      onPointerUp: (_) => _resetPointerTracking(),
      onPointerCancel: (_) => _resetPointerTracking(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Animated arrow slot — collapses smoothly so the WaveformLayer
          // below never changes tree position (its state survives toggles).
          AnimatedSize(
            duration: _toggleDuration,
            curve: _toggleCurve,
            alignment: Alignment.bottomCenter,
            child: AnimatedOpacity(
              duration: _toggleDuration,
              curve: _toggleCurve,
              opacity: widget.showArrow ? 1.0 : 0.0,
              child: widget.showArrow
                  ? AnimatedBuilder(
                      animation: _arrowAnimController,
                      builder: (context, child) {
                        final t = _arrowAnimController.value;
                        final bounce = -4.0 * math.sin(t * math.pi);
                        final opacity =
                            0.72 + 0.28 * math.sin(t * math.pi);
                        return Transform.translate(
                          offset: Offset(0, bounce),
                          child: Opacity(opacity: opacity, child: child!),
                        );
                      },
                      child: Icon(
                        Icons.keyboard_double_arrow_up_rounded,
                        color: Colors.white,
                        size: context.responsive(18.0, 20.0, 22.0),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          AnimatedSize(
            duration: _toggleDuration,
            curve: _toggleCurve,
            child: widget.showArrow
                ? SizedBox(height: context.responsive(2.0, 4.0, 6.0))
                : const SizedBox.shrink(),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: widget.horizontalPadding),
            child: WaveformLayer(
              playerService: widget.playerService,
              positionNotifier: widget.positionNotifier,
              currentSong: widget.currentSong,
            ),
          ),
          if (widget.showTimeLabels) ...[
            SizedBox(height: context.responsive(4.0, 6.0, 8.0)),
            _PlaybackTimeRow(
              playerService: widget.playerService,
              formatDuration: widget.formatDuration,
              currentSong: widget.currentSong,
              horizontalPadding: widget.horizontalPadding,
            ),
          ],
          AnimatedSize(
            duration: _toggleDuration,
            curve: _toggleCurve,
            child: widget.showArrow
                ? SizedBox(height: context.responsive(14.0, 18.0, 22.0))
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

