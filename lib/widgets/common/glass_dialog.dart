import 'dart:ui';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flutter/material.dart';

class GlassDialog extends StatelessWidget {
  final String title;
  final Widget? content;
  final List<Widget>? actions;
  final double? width;
  final double? height;

  const GlassDialog({
    super.key,
    required this.title,
    this.content,
    this.actions,
    this.width,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppConstants.radiusXl),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: AppConstants.glassBlurSigma,
            sigmaY: AppConstants.glassBlurSigma,
          ),
          child: Container(
            width: width ?? 300,
            height: height, // Auto height if null
            padding: const EdgeInsets.all(AppConstants.spacingLg),
            decoration: BoxDecoration(
              color: AppColors.glassBackground,
              borderRadius: BorderRadius.circular(AppConstants.radiusXl),
              border: Border.all(color: AppColors.glassBorder, width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title
                Text(
                  title,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (content != null) ...[
                  const SizedBox(height: AppConstants.spacingMd),
                  // Content
                  DefaultTextStyle(
                    style: Theme.of(context).textTheme.bodyMedium!,
                    child: content!,
                  ),
                ],
                if (actions != null && actions!.isNotEmpty) ...[
                  const SizedBox(height: AppConstants.spacingLg),
                  // Actions
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: actions!.map((action) {
                      return Padding(
                        padding: const EdgeInsets.only(
                          left: AppConstants.spacingXs,
                        ),
                        child: action,
                      );
                    }).toList(),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
