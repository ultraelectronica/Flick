import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/theme/app_colors.dart';

typedef WordBoundaryChanged = void Function(int wordIndex, Duration newStart);
typedef LineEndChanged = void Function(Duration newEnd);

/// Video-style clip strip for one lyric line: a tile per karaoke segment
/// (a whole word, or one syllable of a split word) with width proportional
/// to its duration, draggable boundaries between tiles, and a draggable
/// line-end boundary that retimes the next line. Boundaries inside a word
/// render as lighter grips. All drag proposals are passed through raw;
/// the editor model clamps and snaps.
class WordTimeline extends StatelessWidget {
  final List<String> segmentTexts;
  final List<int> tokenIndexPerSegment;
  final List<({Duration start, Duration end})> windows;
  final int? selectedWordIndex;
  final Duration? playhead;
  final bool lineEndDraggable;
  final ValueChanged<int> onSelectWord;
  final WordBoundaryChanged onBoundaryChanged;
  final LineEndChanged onLineEndChanged;
  final String Function(Duration time) formatTime;

  const WordTimeline({
    super.key,
    required this.segmentTexts,
    required this.tokenIndexPerSegment,
    required this.windows,
    required this.selectedWordIndex,
    required this.playhead,
    required this.lineEndDraggable,
    required this.onSelectWord,
    required this.onBoundaryChanged,
    required this.onLineEndChanged,
    required this.formatTime,
  });

  @override
  Widget build(BuildContext context) {
    if (windows.isEmpty) return const SizedBox.shrink();
    final windowStart = windows.first.start;
    final windowEnd = windows.last.end;
    final totalMs = (windowEnd - windowStart).inMilliseconds;
    if (totalMs <= 0) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              formatTime(windowStart),
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 10,
              ),
            ),
            Text(
              formatTime(windowEnd),
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 10,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        LayoutBuilder(
          builder: (context, constraints) {
            final trackWidth = constraints.maxWidth;
            final msPerPx = totalMs / math.max(1, trackWidth);

            return SizedBox(
              height: 56,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppConstants.radiusSm),
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    Positioned.fill(
                      child: Row(
                        children: [
                          for (var i = 0; i < windows.length; i++)
                            _buildSegment(i),
                        ],
                      ),
                    ),
                    for (var i = 1; i < windows.length; i++)
                      Positioned(
                        top: 0,
                        bottom: 0,
                        width: 20,
                        left:
                            (windows[i].start - windowStart).inMilliseconds *
                            msPerPx -
                            10,
                        child: _BoundaryHandle(
                          boundaryMs: windows[i].start.inMilliseconds,
                          msPerPx: msPerPx,
                          strong:
                              tokenIndexPerSegment[i - 1] !=
                              tokenIndexPerSegment[i],
                          onMoved: (ms) => onBoundaryChanged(
                            i,
                            Duration(milliseconds: ms),
                          ),
                        ),
                      ),
                    if (lineEndDraggable)
                      Positioned(
                        top: 0,
                        bottom: 0,
                        width: 20,
                        left:
                            (windowEnd - windowStart).inMilliseconds *
                            msPerPx -
                            10,
                        child: _BoundaryHandle(
                          boundaryMs: windowEnd.inMilliseconds,
                          msPerPx: msPerPx,
                          strong: true,
                          onMoved: (ms) =>
                              onLineEndChanged(Duration(milliseconds: ms)),
                        ),
                      ),
                    if (playhead != null &&
                        playhead! >= windowStart &&
                        playhead! <= windowEnd)
                      Positioned(
                        top: 0,
                        bottom: 0,
                        width: 2,
                        left:
                            (playhead! - windowStart).inMilliseconds * msPerPx -
                            1,
                        child: Container(color: AppColors.accent),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildSegment(int index) {
    final window = windows[index];
    final durationMs = (window.end - window.start).inMilliseconds;
    final selected = selectedWordIndex == index;
    final label = index < segmentTexts.length ? segmentTexts[index] : '';

    return Expanded(
      flex: math.max(1, durationMs),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onSelectWord(index),
        child: Container(
          decoration: BoxDecoration(
            color: selected ? AppColors.surfaceLight : AppColors.surfaceDark,
            border: Border.all(
              color: selected
                  ? AppColors.accentDim
                  : AppColors.glassBorderStrong,
              width: selected ? 1.5 : 0.5,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected
                      ? AppColors.textPrimary
                      : AppColors.textSecondary,
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${(durationMs / 1000).toStringAsFixed(2)}s',
                maxLines: 1,
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 9,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Invisible drag strip centred on a word boundary. Keeps its own drag
/// anchor so mid-drag rebuilds (from clamped model updates) do not jog
/// the finger position.
class _BoundaryHandle extends StatefulWidget {
  final int boundaryMs;
  final double msPerPx;
  final bool strong;
  final ValueChanged<int> onMoved;

  const _BoundaryHandle({
    required this.boundaryMs,
    required this.msPerPx,
    required this.strong,
    required this.onMoved,
  });

  @override
  State<_BoundaryHandle> createState() => _BoundaryHandleState();
}

class _BoundaryHandleState extends State<_BoundaryHandle> {
  int? _anchorMs;
  double _draggedPx = 0;

  void _reset() {
    _anchorMs = null;
    _draggedPx = 0;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (_) {
        _anchorMs = widget.boundaryMs;
        _draggedPx = 0;
      },
      onHorizontalDragUpdate: (details) {
        final anchor = _anchorMs;
        if (anchor == null) return;
        _draggedPx += details.delta.dx;
        final proposed = anchor + (_draggedPx * widget.msPerPx).round();
        widget.onMoved(proposed);
      },
      onHorizontalDragEnd: (_) => _reset(),
      onHorizontalDragCancel: _reset,
      child: Center(
        child: Container(
          width: widget.strong ? 4 : 2.5,
          height: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.glassBorderStrong.withValues(
              alpha: widget.strong ? 1 : 0.55,
            ),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}
