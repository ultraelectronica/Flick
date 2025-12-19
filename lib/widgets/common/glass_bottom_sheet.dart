import 'dart:ui';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flutter/material.dart';

/// A reusable glassmorphic bottom sheet dialog with Product Sans font.
/// Matches the design language of [GlassDialog] for consistency.
class GlassBottomSheet extends StatelessWidget {
  /// Title displayed at the top of the bottom sheet
  final String? title;

  /// Main content of the bottom sheet
  final Widget? content;

  /// Action buttons at the bottom
  final List<Widget>? actions;

  /// Whether to show the drag handle at the top
  final bool showDragHandle;

  /// Whether the bottom sheet can be dismissed by dragging
  final bool isDismissible;

  /// Whether the bottom sheet can be scrolled
  final bool isScrollControlled;

  /// Maximum height ratio of screen (0.0 to 1.0)
  final double? maxHeightRatio;

  /// Custom padding for the content
  final EdgeInsets? contentPadding;

  const GlassBottomSheet({
    super.key,
    this.title,
    this.content,
    this.actions,
    this.showDragHandle = true,
    this.isDismissible = true,
    this.isScrollControlled = true,
    this.maxHeightRatio,
    this.contentPadding,
  });

  /// Shows the glass bottom sheet as a modal.
  ///
  /// Usage:
  /// ```dart
  /// GlassBottomSheet.show(
  ///   context: context,
  ///   title: 'Select Option',
  ///   content: MyContentWidget(),
  ///   actions: [
  ///     TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel')),
  ///     ElevatedButton(onPressed: () {}, child: Text('Confirm')),
  ///   ],
  /// );
  /// ```
  static Future<T?> show<T>({
    required BuildContext context,
    String? title,
    Widget? content,
    List<Widget>? actions,
    bool showDragHandle = true,
    bool isDismissible = true,
    bool isScrollControlled = true,
    double? maxHeightRatio,
    EdgeInsets? contentPadding,
    bool enableDrag = true,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      isDismissible: isDismissible,
      enableDrag: enableDrag,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (context) => GlassBottomSheet(
        title: title,
        content: content,
        actions: actions,
        showDragHandle: showDragHandle,
        isDismissible: isDismissible,
        isScrollControlled: isScrollControlled,
        maxHeightRatio: maxHeightRatio,
        contentPadding: contentPadding,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final maxHeight = maxHeightRatio != null
        ? mediaQuery.size.height * maxHeightRatio!
        : mediaQuery.size.height * 0.85;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(AppConstants.radiusXl),
          topRight: Radius.circular(AppConstants.radiusXl),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 24,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(AppConstants.radiusXl),
          topRight: Radius.circular(AppConstants.radiusXl),
        ),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: AppConstants.glassBlurSigma,
            sigmaY: AppConstants.glassBlurSigma,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.glassBackground,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(AppConstants.radiusXl),
                topRight: Radius.circular(AppConstants.radiusXl),
              ),
              border: Border.all(color: AppColors.glassBorder, width: 1),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag Handle
                if (showDragHandle) _buildDragHandle(),

                // Title
                if (title != null) _buildTitle(context),

                // Content
                if (content != null)
                  Flexible(
                    child: Padding(
                      padding:
                          contentPadding ??
                          const EdgeInsets.symmetric(
                            horizontal: AppConstants.spacingLg,
                          ),
                      child: DefaultTextStyle(
                        style: Theme.of(context).textTheme.bodyMedium!,
                        child: content!,
                      ),
                    ),
                  ),

                // Actions
                if (actions != null && actions!.isNotEmpty)
                  _buildActions(context),

                // Bottom safe area padding
                SizedBox(
                  height: mediaQuery.padding.bottom + AppConstants.spacingLg,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDragHandle() {
    return Container(
      padding: const EdgeInsets.only(top: AppConstants.spacingSm),
      child: Center(
        child: Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: AppColors.textTertiary,
            borderRadius: BorderRadius.circular(AppConstants.radiusRound),
          ),
        ),
      ),
    );
  }

  Widget _buildTitle(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppConstants.spacingLg,
        AppConstants.spacingMd,
        AppConstants.spacingLg,
        AppConstants.spacingSm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title!,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          if (isDismissible)
            GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                padding: const EdgeInsets.all(AppConstants.spacingXs),
                decoration: BoxDecoration(
                  color: AppColors.glassBackground,
                  borderRadius: BorderRadius.circular(AppConstants.radiusMd),
                ),
                child: const Icon(
                  Icons.close_rounded,
                  color: AppColors.textSecondary,
                  size: 20,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildActions(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppConstants.spacingLg,
        AppConstants.spacingMd,
        AppConstants.spacingLg,
        AppConstants.spacingMd,
      ),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.glassBorder, width: 1)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: actions!.map((action) {
          return Padding(
            padding: const EdgeInsets.only(left: AppConstants.spacingXs),
            child: action,
          );
        }).toList(),
      ),
    );
  }
}

/// Extension methods for easily showing glass bottom sheets
extension GlassBottomSheetExtension on BuildContext {
  /// Shows a glass bottom sheet with the given configuration.
  Future<T?> showGlassBottomSheet<T>({
    String? title,
    Widget? content,
    List<Widget>? actions,
    bool showDragHandle = true,
    bool isDismissible = true,
    bool isScrollControlled = true,
    double? maxHeightRatio,
    EdgeInsets? contentPadding,
    bool enableDrag = true,
  }) {
    return GlassBottomSheet.show<T>(
      context: this,
      title: title,
      content: content,
      actions: actions,
      showDragHandle: showDragHandle,
      isDismissible: isDismissible,
      isScrollControlled: isScrollControlled,
      maxHeightRatio: maxHeightRatio,
      contentPadding: contentPadding,
      enableDrag: enableDrag,
    );
  }
}
