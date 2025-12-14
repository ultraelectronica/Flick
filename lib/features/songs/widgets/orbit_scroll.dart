import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flick_player/core/theme/app_colors.dart';
import 'package:flick_player/core/constants/app_constants.dart';
import 'package:flick_player/models/song.dart';
import 'package:flick_player/features/songs/widgets/song_card.dart';

/// Orbital scrolling widget that displays songs in a curved arc.
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
  late AnimationController _controller;

  // The physics state
  double _scrollOffset = 0.0;

  @override
  void initState() {
    super.initState();
    _scrollOffset = widget.selectedIndex.toDouble();
    _controller = AnimationController.unbounded(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _controller.addListener(_onPhysicsTick);
  }

  @override
  void didUpdateWidget(OrbitScroll oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedIndex != oldWidget.selectedIndex) {
      // If the index changed externally, snap/spring to it
      if ((widget.selectedIndex.toDouble() - _scrollOffset).abs() > 0.05) {
        _animateTo(widget.selectedIndex.toDouble());
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onPhysicsTick() {
    // The controller value IS the scroll offset during an animation
    if (_controller.isAnimating) {
      setState(() {
        _scrollOffset = _controller.value;
      });

      // Report index changes while scrolling
      final currentIndex = _scrollOffset.round();
      if (currentIndex >= 0 &&
          currentIndex < widget.songs.length &&
          widget.onSelectedIndexChanged != null) {
        // Debounce or check duplicates is handled by listener usually,
        // but we'll leave it to the parent to handle strictness.
        // For purely visual updates, this is fine.
      }
    }
  }

  // --- Gesture Handling ---

  void _onVerticalDragStart(DragStartDetails details) {
    _controller.stop();
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    // 1. Calculate delta in pixels
    final delta = details.primaryDelta ?? 0.0;

    // Dispatch scroll notification
    // We send a ScrollUpdateNotification kind of event, but simple UserScrollNotification is easier for direction
    if (delta != 0) {
      final direction = delta > 0
          ? ScrollDirection.reverse
          : ScrollDirection.forward;
      // Reverse = Down (dragging down, list moves down, showing top items -> scrolling UP effectively?)
      // Wait, standard flutter:
      // Dragging Up (negative delta) = Scrolling Down (index increases)
      // Dragging Down (positive delta) = Scrolling Up (index decreases)

      UserScrollNotification(
        metrics: FixedScrollMetrics(
          minScrollExtent: 0,
          maxScrollExtent: widget.songs.length.toDouble(),
          pixels: _scrollOffset,
          viewportDimension: 100,
          axisDirection: AxisDirection.down,
          devicePixelRatio: 1.0,
        ),
        context: context,
        direction: direction,
      ).dispatch(context);
    }

    // 2. Convert to 'item' units.
    // Making this dynamic gives a better feel.
    // 1 item = ~80-100 pixels feels right for a wheel.
    const itemHeight = 90.0;
    final itemDelta = -(delta / itemHeight);

    // 3. Apply resistance if out of bounds (Overscroll)
    double newOffset = _scrollOffset + itemDelta;
    if (newOffset < -0.5 || newOffset > widget.songs.length - 0.5) {
      // Apply square root damping for boundaries
      // Standard flutter overscroll logic usually applies friction
      itemDelta / 2; // Simple resistance
      newOffset = _scrollOffset + (itemDelta * 0.4); // Stiff resistance
    }

    setState(() {
      _scrollOffset = newOffset;
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    // _dragStart = null; // This variable is not defined in the provided context. Removing it.
    final velocity = details.primaryVelocity ?? 0.0;

    // Dispatch end notification (idle)
    UserScrollNotification(
      metrics: FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: widget.songs.length.toDouble(),
        pixels: _scrollOffset,
        viewportDimension: 100,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1.0,
      ),
      context: context,
      direction: ScrollDirection.idle,
    ).dispatch(context);

    // Pixels per second
    // Convert to items per second
    const itemHeight = 90.0;
    final velocityItemsPerSec = -velocity / itemHeight;

    // 1. Predict landing point
    // We use a FrictionSimulation to see where it WOULD land.
    final simulation = FrictionSimulation(
      0.15, // Drag coefficient (higher = stops faster)
      _scrollOffset,
      velocityItemsPerSec,
    );

    final finalTime = 2.0; // Simulate far enough ahead
    final projectedOffset = simulation.x(finalTime);

    // 2. Snap to nearest valid item
    final targetIndex = projectedOffset.round().clamp(
      0,
      widget.songs.length - 1,
    );

    // 3. Spring to that target
    _animateTo(targetIndex.toDouble(), velocity: velocityItemsPerSec);
  }

  void _animateTo(double target, {double velocity = 0.0}) {
    // Create a spring simulation from current => target
    final description = SpringDescription.withDampingRatio(
      mass: 1.0,
      stiffness: 100.0, // Reasonable stiffness for UI
      ratio: 1.0, // Critically damped (no bounce unless overshooting)
    );

    final simulation = SpringSimulation(
      description,
      _scrollOffset,
      target,
      velocity,
    );

    _controller.animateWith(simulation).whenComplete(() {
      // Ensure we explicitly set the final state to avoid micro-drifts
      setState(() {
        _scrollOffset = target;
      });
      final finalIndex = target.round();
      if (finalIndex >= 0 && finalIndex < widget.songs.length) {
        widget.onSelectedIndexChanged?.call(finalIndex);
      }
    });
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
            // Background glow
            _buildSelectionGlow(orbitCenterX, orbitCenterY, orbitRadius),

            // Path
            _buildOrbitPath(orbitCenterX, orbitCenterY, orbitRadius),

            // Songs
            ..._buildSongItems(orbitCenterX, orbitCenterY, orbitRadius),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectionGlow(double centerX, double centerY, double radius) {
    final x = centerX + radius;
    final y = centerY;
    return Positioned(
      left: x - 120, // Slightly larger glow
      top: y - 120,
      child: Container(
        width: 240,
        height: 240,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              AppColors.accent.withValues(alpha: 0.15),
              Colors.transparent,
            ],
            stops: const [0.0, 0.7],
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
    // Increase visible range for smoother scrolling entry/exit
    final visibleRange = AppConstants.orbitVisibleItems ~/ 2 + 3;

    final orderedIndices = <int>[];
    for (var i = -visibleRange; i <= visibleRange; i++) {
      orderedIndices.add(i);
    }
    // Sort by distance (render far items first)
    orderedIndices.sort((a, b) => b.abs().compareTo(a.abs()));

    for (final relativeIndex in orderedIndices) {
      // Determine which song index this slot corresponds to
      // Logic:
      // If we are at offset 5.2:
      // relative 0 => index 5 (closest)
      // relative 1 => index 6
      // relative -1 => index 4
      // This part handles the "infinite" feel or just mapping relative to absolute
      final centerIndex = _scrollOffset.round();
      final actualIndex = centerIndex + relativeIndex;

      if (actualIndex < 0 || actualIndex >= widget.songs.length) continue;

      // Calculate the visual offset angle based on exact scroll position
      // _scrollOffset = 5.2
      // actualIndex = 5 (center)
      // relativeIndex = 0
      // diff = 5 - 5.2 = -0.2 (It's slightly above center)
      final diff = actualIndex.toDouble() - _scrollOffset;

      final position = _calculateItemPosition(diff, centerX, centerY, radius);

      final distanceFromCenter = diff.abs();

      // Dynamic scaling based on distance
      double scale;
      if (distanceFromCenter < 0.5) {
        scale = AppConstants.orbitSelectedScale;
      } else if (distanceFromCenter < 1.5) {
        scale = AppConstants.orbitAdjacentScale;
      } else {
        scale =
            AppConstants.orbitDistantScale - (distanceFromCenter - 1.5) * 0.12;
      }
      scale = scale.clamp(0.0, 1.25);

      if (scale < 0.1) continue;

      double opacity = 1.0 - (distanceFromCenter * 0.25);
      opacity = opacity.clamp(0.0, 1.0);

      // Tilt effect: rotate items slightly as they move up/down
      // Simple rotation: proportional to angle?
      // Actually, standard list items don't rotate, but for orbit it might look cool.
      // Let's keep it simple for now to match the "Revamp scrolling" request primarily about feel.

      final isSelected =
          distanceFromCenter < 0.4; // Tighter selection threshold

      items.add(
        Positioned(
          left: position.x,
          top: position.y,
          child: FractionalTranslation(
            translation: const Offset(-0.5, -0.5),
            child: SongCard(
              song: widget.songs[actualIndex],
              scale: scale,
              opacity: opacity,
              isSelected: isSelected,
              onTap: () {
                _animateTo(actualIndex.toDouble());
                widget.onSongSelected?.call(actualIndex);
              },
            ),
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
    // Relative index acts as the angle factor
    // 0 = Center right (0 degrees in our logic?)
    // Actually, in the previous code:
    // angle = relativeIndex * spacing
    // x = center + radius * cos(angle)
    // y = center + radius * sin(angle)

    final angle = relativeIndex * AppConstants.orbitItemSpacing;

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
      ..color = AppColors.glassBorder.withValues(alpha: 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    final rect = Rect.fromCircle(
      center: Offset(centerX, centerY),
      radius: radius,
    );

    canvas.drawArc(rect, -math.pi / 2.5, 2 * math.pi / 2.5, false, paint);
  }

  @override
  bool shouldRepaint(covariant _OrbitPathPainter oldDelegate) {
    return centerX != oldDelegate.centerX ||
        centerY != oldDelegate.centerY ||
        radius != oldDelegate.radius;
  }
}
