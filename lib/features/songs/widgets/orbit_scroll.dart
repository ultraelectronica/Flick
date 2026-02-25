import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/models/song.dart';
import 'package:flick/features/songs/widgets/song_card.dart';

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

  // Track if we're actively scrolling to reduce visible range when idle
  bool _isScrolling = false;
  DateTime _lastScrollTime = DateTime.now();

  // Cache for transform calculations
  final Map<int, _Position> _positionCache = {};
  final Map<int, _ItemTransform> _transformCache = {};

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
    if (_controller.isAnimating) {
      final newOffset = _controller.value;
      if ((newOffset - _scrollOffset).abs() > 0.001) {
        setState(() {
          _scrollOffset = newOffset;
          _isScrolling = true;
          _lastScrollTime = DateTime.now();
        });
      }
    } else if (_isScrolling) {
      final now = DateTime.now();
      if (now.difference(_lastScrollTime).inMilliseconds > 100) {
        setState(() {
          _isScrolling = false;
        });
      }
    }
  }

  // --- Gesture Handling ---

  void _onVerticalDragStart(DragStartDetails details) {
    _controller.stop();
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    final delta = details.primaryDelta ?? 0.0;
    if (delta == 0) return;

    final direction = delta > 0
        ? ScrollDirection.reverse
        : ScrollDirection.forward;

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

    const itemHeight = 90.0;
    var itemDelta = -(delta / itemHeight);

    double newOffset = _scrollOffset + itemDelta;
    if (newOffset < -0.5 || newOffset > widget.songs.length - 0.5) {
      itemDelta = itemDelta * 0.4;
      newOffset = _scrollOffset + itemDelta;
    }

    if ((newOffset - _scrollOffset).abs() > 0.001) {
      setState(() {
        _scrollOffset = newOffset;
        _isScrolling = true;
        _lastScrollTime = DateTime.now();
      });
    }
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
        _isScrolling = false;
        _lastScrollTime = DateTime.now();
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
    final orbitCenterY =
        size.height * 0.42; // Higher on screen for better visibility

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
      child: RepaintBoundary(
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
      ),
    );
  }

  Widget _buildOrbitPath(double centerX, double centerY, double radius) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _OrbitPathPainter(
          centerX: centerX,
          centerY: centerY,
          radius: radius,
        ),
      ),
    );
  }

  List<Widget> _buildSongItems(double centerX, double centerY, double radius) {
    final List<Widget> items = [];

    final visibleRange = AppConstants.orbitVisibleItems ~/ 2;

    final orderedIndices = List.generate(
      visibleRange * 2 + 1,
      (i) => i - visibleRange,
    )..sort((a, b) => b.abs().compareTo(a.abs()));

    final centerIndex = _scrollOffset.round();
    final useCache = !_isScrolling;

    for (final relativeIndex in orderedIndices) {
      final actualIndex = centerIndex + relativeIndex;

      if (actualIndex < 0 || actualIndex >= widget.songs.length) continue;

      final diff = actualIndex.toDouble() - _scrollOffset;

      _ItemTransform? transform;
      if (useCache) {
        final cacheKey = (diff * 100).toInt();
        transform = _transformCache[cacheKey];
      }

      if (transform == null) {
        final position = _calculateItemPosition(diff, centerX, centerY, radius);
        final distanceFromCenter = diff.abs();

        double scale;
        if (distanceFromCenter < 1.0) {
          scale =
              AppConstants.orbitSelectedScale -
              (AppConstants.orbitSelectedScale -
                      AppConstants.orbitAdjacentScale) *
                  distanceFromCenter;
        } else if (distanceFromCenter < 2.0) {
          scale =
              AppConstants.orbitAdjacentScale -
              (AppConstants.orbitAdjacentScale -
                      AppConstants.orbitDistantScale) *
                  (distanceFromCenter - 1.0);
        } else {
          scale =
              AppConstants.orbitDistantScale -
              (distanceFromCenter - 2.0) * 0.12;
        }
        scale = scale.clamp(0.0, 1.25);

        if (scale < 0.1) continue;

        final opacity = (1.0 - (distanceFromCenter * 0.25)).clamp(0.0, 1.0);
        final isSelected = distanceFromCenter < 0.4;

        transform = _ItemTransform(
          position: position,
          scale: scale,
          opacity: opacity,
          isSelected: isSelected,
        );

        if (useCache) {
          final cacheKey = (diff * 100).toInt();
          _transformCache[cacheKey] = transform;
        }
      }

      items.add(
        Positioned(
          left: transform.position.x,
          top: transform.position.y,
          child: FractionalTranslation(
            translation: const Offset(-0.5, -0.5),
            child: RepaintBoundary(
              child: SongCard(
                song: widget.songs[actualIndex],
                scale: transform.scale,
                opacity: transform.opacity,
                isSelected: transform.isSelected,
                onTap: () {
                  _animateTo(actualIndex.toDouble());
                  widget.onSongSelected?.call(actualIndex);
                },
              ),
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
    final cacheKey = (relativeIndex * 100).toInt();

    final existing = _positionCache[cacheKey];
    if (existing != null) {
      return existing;
    }

    // Split effect: push adjacent items away from the center highlighted item
    double adjustedIndex = relativeIndex;
    final double splitAmount =
        0.55; // Determines how much the items split apart
    adjustedIndex +=
        relativeIndex.sign * splitAmount * math.min(relativeIndex.abs(), 1.0);

    final angle = adjustedIndex * AppConstants.orbitItemSpacing;
    final x = centerX + radius * math.cos(angle);
    final y = centerY + radius * math.sin(angle);

    final position = _Position(x, y);

    if (!_isScrolling) {
      _positionCache[cacheKey] = position;
    }

    return position;
  }
}

class _Position {
  final double x;
  final double y;
  const _Position(this.x, this.y);
}

/// Cached transform data for orbit items
class _ItemTransform {
  final _Position position;
  final double scale;
  final double opacity;
  final bool isSelected;

  const _ItemTransform({
    required this.position,
    required this.scale,
    required this.opacity,
    required this.isSelected,
  });
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
