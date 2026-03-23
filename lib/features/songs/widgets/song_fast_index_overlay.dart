import 'package:flutter/material.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/theme/app_colors.dart';

typedef FastIndexSelectCallback = void Function(String token, bool animate);

class SongFastIndexOverlay extends StatefulWidget {
  static const List<String> defaultTokens = <String>[
    'A',
    'B',
    'C',
    'D',
    'E',
    'F',
    'G',
    'H',
    'I',
    'J',
    'K',
    'L',
    'M',
    'N',
    'O',
    'P',
    'Q',
    'R',
    'S',
    'T',
    'U',
    'V',
    'W',
    'X',
    'Y',
    'Z',
    '0-9',
    '#',
  ];

  final Map<String, int> tokenToIndex;
  final FastIndexSelectCallback onSelect;
  final String? selectedToken;
  final List<String> tokens;

  const SongFastIndexOverlay({
    super.key,
    required this.tokenToIndex,
    required this.onSelect,
    this.selectedToken,
    this.tokens = defaultTokens,
  });

  @override
  State<SongFastIndexOverlay> createState() => _SongFastIndexOverlayState();
}

class _SongFastIndexOverlayState extends State<SongFastIndexOverlay> {
  String? _activeToken;
  String? _dragToken;
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _activeToken = widget.selectedToken ?? widget.tokens.first;
  }

  @override
  void didUpdateWidget(covariant SongFastIndexOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isDragging &&
        widget.selectedToken != null &&
        widget.selectedToken != _activeToken) {
      _activeToken = widget.selectedToken;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = widget.tokens
        .where(widget.tokenToIndex.containsKey)
        .toList(growable: false);
    if (tokens.isEmpty) {
      return const SizedBox.shrink();
    }

    if (_activeToken == null || !tokens.contains(_activeToken)) {
      _activeToken = tokens.first;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        const railPadding = AppConstants.spacingXs;
        final usableHeight = (constraints.maxHeight - (railPadding * 2)).clamp(
          0.0,
          double.infinity,
        );
        final spacing = (usableHeight / tokens.length).clamp(8.0, 18.0);

        return Stack(
          clipBehavior: Clip.none,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) {
                final token = _tokenFromOffset(
                  localDy: details.localPosition.dy,
                  tokens: tokens,
                  spacing: spacing,
                );
                if (token == null) return;
                _activeToken = token;
                widget.onSelect(token, true);
                setState(() {});
              },
              onVerticalDragStart: (details) {
                setState(() {
                  _isDragging = true;
                });
                final token = _tokenFromOffset(
                  localDy: details.localPosition.dy,
                  tokens: tokens,
                  spacing: spacing,
                );
                if (token == null) return;
                if (_dragToken != token) {
                  _dragToken = token;
                  widget.onSelect(token, false);
                }
                setState(() {});
              },
              onVerticalDragUpdate: (details) {
                final token = _tokenFromOffset(
                  localDy: details.localPosition.dy,
                  tokens: tokens,
                  spacing: spacing,
                );
                if (token == null || _dragToken == token) return;
                _dragToken = token;
                widget.onSelect(token, false);
                setState(() {});
              },
              onVerticalDragEnd: (_) {
                setState(() {
                  _isDragging = false;
                  if (_dragToken != null) {
                    _activeToken = _dragToken;
                  }
                });
              },
              onVerticalDragCancel: () {
                setState(() {
                  _isDragging = false;
                  if (_dragToken != null) {
                    _activeToken = _dragToken;
                  }
                });
              },
              child: Container(
                width: 26,
                decoration: BoxDecoration(
                  color: AppColors.surface.withValues(alpha: 0.32),
                  borderRadius: BorderRadius.circular(AppConstants.radiusLg),
                  border: Border.all(color: AppColors.glassBorder),
                ),
                padding: const EdgeInsets.symmetric(
                  vertical: AppConstants.spacingSm,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final token in tokens)
                      SizedBox(
                        height: spacing,
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 120),
                          style:
                              Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: _colorForToken(context, token),
                                fontWeight: _isHighlighted(token)
                                    ? FontWeight.w700
                                    : FontWeight.w600,
                                fontSize: _isDragging && _dragToken == token
                                    ? 11.5
                                    : 9.5,
                                height: 1,
                              ) ??
                              const TextStyle(),
                          child: Center(child: Text(token, maxLines: 1)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (_isDragging && _dragToken != null)
              Positioned(
                right: 34,
                top: constraints.maxHeight * 0.5 - 24,
                child: Container(
                  width: 56,
                  height: 48,
                  decoration: BoxDecoration(
                    color: AppColors.surface.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(AppConstants.radiusMd),
                    border: Border.all(
                      color: AppColors.accent.withValues(alpha: 0.7),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.25),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    _dragToken!,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: AppColors.accent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  bool _isHighlighted(String token) {
    return (_isDragging && _dragToken == token) ||
        (!_isDragging && _activeToken == token);
  }

  Color _colorForToken(BuildContext context, String token) {
    if (_isHighlighted(token)) {
      return AppColors.accent;
    }

    if (widget.tokenToIndex.containsKey(token)) {
      return context.adaptiveTextSecondary;
    }

    return context.adaptiveTextTertiary.withValues(alpha: 0.45);
  }

  String? _tokenFromOffset({
    required double localDy,
    required List<String> tokens,
    required double spacing,
  }) {
    if (tokens.isEmpty || spacing <= 0) return null;

    final adjusted = localDy.clamp(0.0, spacing * tokens.length - 0.01);
    final tokenIndex = (adjusted / spacing).floor().clamp(0, tokens.length - 1);
    return tokens[tokenIndex];
  }
}
