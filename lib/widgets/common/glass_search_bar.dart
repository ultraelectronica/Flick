import 'package:flutter/material.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/widgets/common/glassmorphism_container.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A reusable search bar widget applying the glassmorphism design language.
class GlassSearchBar extends StatefulWidget {
  /// The controller for the search text field
  final TextEditingController controller;

  /// Callback when the search text changes
  final ValueChanged<String>? onChanged;

  /// Hint text to display when the search bar is empty
  final String hintText;

  /// Callback when the search bar is cleared via the clear button
  final VoidCallback? onClear;

  /// Whether to show the glass background (default: true)
  final bool showBackground;

  const GlassSearchBar({
    super.key,
    required this.controller,
    this.onChanged,
    this.hintText = 'Search...',
    this.onClear,
    this.showBackground = true,
  });

  @override
  State<GlassSearchBar> createState() => _GlassSearchBarState();
}

class _GlassSearchBarState extends State<GlassSearchBar> {
  bool _showClearButton = false;

  @override
  void initState() {
    super.initState();
    _showClearButton = widget.controller.text.isNotEmpty;
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    final showClear = widget.controller.text.isNotEmpty;
    if (_showClearButton != showClear) {
      if (mounted) {
        setState(() {
          _showClearButton = showClear;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppConstants.spacingMd,
        vertical: AppConstants.spacingSm,
      ),
      child: Row(
        children: [
          Icon(
            LucideIcons.search,
            color: context.adaptiveTextSecondary,
            size: AppConstants.iconSizeMd,
          ),
          const SizedBox(width: AppConstants.spacingSm),
          Expanded(
            child: TextField(
              controller: widget.controller,
              onChanged: widget.onChanged,
              style: TextStyle(
                color: context.adaptiveTextPrimary,
                fontSize: 16,
              ),
              decoration: InputDecoration(
                hintText: widget.hintText,
                hintStyle: TextStyle(color: context.adaptiveTextTertiary),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              cursorColor: AppColors.accent,
            ),
          ),
          if (_showClearButton)
            GestureDetector(
              onTap: () {
                widget.controller.clear();
                widget.onChanged?.call('');
                widget.onClear?.call();
              },
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.only(left: AppConstants.spacingSm),
                child: Icon(
                  LucideIcons.x,
                  color: context.adaptiveTextSecondary,
                  size: AppConstants.iconSizeMd,
                ),
              ),
            ),
        ],
      ),
    );

    if (widget.showBackground) {
      return GlassmorphismContainer(
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(AppConstants.radiusXl),
        child: content,
      );
    }

    return content;
  }
}
