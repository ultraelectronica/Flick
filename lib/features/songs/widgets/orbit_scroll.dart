import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flick_player/core/theme/app_colors.dart';
import 'package:flick_player/core/constants/app_constants.dart';
import 'package:flick_player/models/song.dart';
import 'package:flick_player/features/songs/widgets/song_card.dart';

/// Orbital scrolling widget that displays songs in a half-circle arc on the left side.
class OrbitScroll extends StatefulWidget {
  /// List of songs to display
  final List<Song> songs;

  /// Index of the currently selected song
  final int selectedIndex;

  /// Callback when a song is selected
  final ValueChanged<int>? onSongSelected;

  /// Callback when the selected song changes via scrolling
  final ValueChanged<int>? onSelectedIndexChanged;

  const OrbitScroll({
    super.key,
    required this.songs,
    this.selectedIndex = 0,
    this.onSongSelected,
    this.onSelectedIndexChanged,
  });

  @override
  State<OrbitScroll> createState() => _OrbitScrollState();
}

class _OrbitScrollState extends State<OrbitScroll>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;

  // Current scroll offset in items (can be fractional)
  double _scrollOffset = 0.0;

  // For tracking drag gestures
  double _lastDragY = 0.0;

  @override
  void initState() {
    super.initState();
    _scrollOffset = widget.selectedIndex.toDouble();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    _animationController.addListener(_onAnimationTick);
  }

  @override
  void didUpdateWidget(OrbitScroll oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedIndex != oldWidget.selectedIndex) {
      _animateToIndex(widget.selectedIndex);
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _onAnimationTick() {
    if (_animationController.isAnimating) {
      setState(() {});
    }
  }

  void _animateToIndex(int index) {
    final targetOffset = index.toDouble();
    final distance = (targetOffset - _scrollOffset).abs();

    _animationController.reset();

    final Animation<double> animation = _animationController.drive(
      Tween<double>(
        begin: _scrollOffset,
        end: targetOffset,
      ).chain(CurveTween(curve: Curves.easeOutCubic)),
    );

    animation.addListener(() {
      setState(() {
        _scrollOffset = animation.value;
      });
    });

    _animationController.duration = Duration(
      milliseconds: (300 + distance * 50).clamp(300, 800).toInt(),
    );
    _animationController.forward();
  }

  void _onVerticalDragStart(DragStartDetails details) {
    _animationController.stop();
    _lastDragY = details.globalPosition.dy;
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    final delta = details.globalPosition.dy - _lastDragY;
    _lastDragY = details.globalPosition.dy;

    // Convert pixel movement to scroll offset
    // Negative delta (swipe up) should increase offset (go to next song)
    final scrollDelta = -delta / 100.0;

    setState(() {
      _scrollOffset = (_scrollOffset + scrollDelta).clamp(
        0.0,
        (widget.songs.length - 1).toDouble(),
      );
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    // Snap to nearest item
    final nearestIndex = _scrollOffset.round().clamp(
      0,
      widget.songs.length - 1,
    );
    _animateToIndex(nearestIndex);

    // Notify parent of selection change
    if (nearestIndex != widget.selectedIndex) {
      widget.onSelectedIndexChanged?.call(nearestIndex);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    // Calculate orbit parameters
    final orbitRadius = size.width * AppConstants.orbitRadiusRatio;
    final orbitCenterX = size.width * AppConstants.orbitCenterOffsetRatio;
    final orbitCenterY = size.height / 2;

    return GestureDetector(
      onVerticalDragStart: _onVerticalDragStart,
      onVerticalDragUpdate: _onVerticalDragUpdate,
      onVerticalDragEnd: _onVerticalDragEnd,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        height: double.infinity,
        color: Colors.transparent,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Background glow for selected item
            _buildSelectionGlow(orbitCenterX, orbitCenterY, orbitRadius),

            // Orbit path visualization (subtle)
            _buildOrbitPath(orbitCenterX, orbitCenterY, orbitRadius),

            // Song items
            ..._buildSongItems(orbitCenterX, orbitCenterY, orbitRadius),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectionGlow(double centerX, double centerY, double radius) {
    // Calculate position of selected item
    final position = _calculateItemPosition(
      0, // Center position in relative terms
      centerX,
      centerY,
      radius,
    );

    return Positioned(
      left: position.x - 80,
      top: position.y - 80,
      child: Container(
        width: 160,
        height: 160,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              Colors.white.withValues(alpha: 0.08),
              Colors.white.withValues(alpha: 0.02),
              Colors.transparent,
            ],
            stops: const [0.0, 0.5, 1.0],
          ),
        ),
      ),
    );
  }

  Widget _buildOrbitPath(double centerX, double centerY, double radius) {
    return CustomPaint(
      size: Size.infinite,
      painter: _OrbitPathPainter(
        centerX: centerX,
        centerY: centerY,
        radius: radius,
      ),
    );
  }

  List<Widget> _buildSongItems(double centerX, double centerY, double radius) {
    final List<Widget> items = [];
    final visibleRange = AppConstants.orbitVisibleItems ~/ 2 + 1;

    // Build items from furthest to nearest (for proper z-ordering)
    final orderedIndices = <int>[];

    for (var i = -visibleRange; i <= visibleRange; i++) {
      orderedIndices.add(i);
    }

    // Sort by absolute distance from center (render far items first)
    orderedIndices.sort((a, b) => b.abs().compareTo(a.abs()));

    for (final relativeIndex in orderedIndices) {
      final actualIndex = _scrollOffset.round() + relativeIndex;

      if (actualIndex < 0 || actualIndex >= widget.songs.length) continue;

      // Calculate the fractional offset for smooth animation
      final fractionalOffset = _scrollOffset - _scrollOffset.floor();
      final adjustedRelativeIndex =
          relativeIndex -
          fractionalOffset +
          (_scrollOffset.floor() - _scrollOffset.round());

      final position = _calculateItemPosition(
        adjustedRelativeIndex,
        centerX,
        centerY,
        radius,
      );

      final distanceFromCenter = adjustedRelativeIndex.abs();

      // Calculate scale based on distance from center
      double scale;
      if (distanceFromCenter < 0.5) {
        scale = AppConstants.orbitSelectedScale;
      } else if (distanceFromCenter < 1.5) {
        scale = AppConstants.orbitAdjacentScale;
      } else {
        scale =
            AppConstants.orbitDistantScale - (distanceFromCenter - 1.5) * 0.1;
      }
      scale = scale.clamp(0.4, 1.0);

      // Calculate opacity based on distance
      double opacity = 1.0 - (distanceFromCenter * 0.15);
      opacity = opacity.clamp(0.3, 1.0);

      final isSelected = distanceFromCenter < 0.5;

      items.add(
        Positioned(
          left: position.x,
          top: position.y - 50, // Offset to center the card
          child: SongCard(
            song: widget.songs[actualIndex],
            scale: scale,
            opacity: opacity,
            isSelected: isSelected,
            onTap: () {
              _animateToIndex(actualIndex);
              widget.onSongSelected?.call(actualIndex);
            },
          ),
        ),
      );
    }

    return items;
  }

  _Position _calculateItemPosition(
    double relativeIndex,
    double centerX,
    double centerY,
    double radius,
  ) {
    // Each item is spaced along the arc
    // 0 = center (3 o'clock position for a circle centered off-screen left)
    // Positive = below center, Negative = above center
    final angle = relativeIndex * AppConstants.orbitItemSpacing;

    // For a half-circle on the left, we use angles from -π/2 to π/2
    // Centered at 0 (pointing right)
    final x = centerX + radius * math.cos(angle);
    final y = centerY + radius * math.sin(angle);

    return _Position(x, y);
  }
}

class _Position {
  final double x;
  final double y;

  const _Position(this.x, this.y);
}

/// Custom painter for the subtle orbit path visualization
class _OrbitPathPainter extends CustomPainter {
  final double centerX;
  final double centerY;
  final double radius;

  _OrbitPathPainter({
    required this.centerX,
    required this.centerY,
    required this.radius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.glassBorder.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    // Draw the visible arc portion
    final rect = Rect.fromCircle(
      center: Offset(centerX, centerY),
      radius: radius,
    );

    // Draw arc from -π/2 to π/2 (right half of circle)
    canvas.drawArc(rect, -math.pi / 2, math.pi, false, paint);
  }

  @override
  bool shouldRepaint(covariant _OrbitPathPainter oldDelegate) {
    return centerX != oldDelegate.centerX ||
        centerY != oldDelegate.centerY ||
        radius != oldDelegate.radius;
  }
}
