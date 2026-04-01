import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/src/rust/api/uac2_api.dart' as rust_uac2;

class Uac2FallbackManager extends ConsumerStatefulWidget {
  const Uac2FallbackManager({super.key});

  @override
  ConsumerState<Uac2FallbackManager> createState() =>
      _Uac2FallbackManagerState();
}

class _Uac2FallbackManagerState extends ConsumerState<Uac2FallbackManager> {
  Timer? _updateTimer;
  rust_uac2.Uac2FallbackInfo? _fallbackInfo;

  @override
  void initState() {
    super.initState();
    _startUpdating();
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }

  void _startUpdating() {
    _updateTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _loadFallbackInfo();
    });
    _loadFallbackInfo();
  }

  Future<void> _loadFallbackInfo() async {
    final service = ref.read(uac2ServiceProvider);
    final info = await service.getFallbackInfo();

    if (mounted && info != null) {
      setState(() => _fallbackInfo = info);
    }
  }

  Future<void> _activateFallback() async {
    final service = ref.read(uac2ServiceProvider);
    final success = await service.activateFallback();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? 'Fallback audio activated'
                : 'Failed to activate fallback',
          ),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }

    await _loadFallbackInfo();
  }

  Future<void> _deactivateFallback() async {
    final service = ref.read(uac2ServiceProvider);
    final success = await service.deactivateFallback();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? 'Fallback audio deactivated'
                : 'Failed to deactivate fallback',
          ),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }

    await _loadFallbackInfo();
  }

  @override
  Widget build(BuildContext context) {
    final deviceStatus = ref.watch(uac2DeviceStatusProvider);

    if (deviceStatus == null) {
      return const SizedBox.shrink();
    }

    if (_fallbackInfo == null) {
      return Container(
        padding: const EdgeInsets.all(AppConstants.spacingLg),
        decoration: BoxDecoration(
          color: AppColors.surface.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(AppConstants.radiusLg),
          border: Border.all(color: AppColors.glassBorder),
        ),
        child: const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(AppConstants.spacingMd),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                LucideIcons.lifeBuoy,
                color: context.adaptiveTextSecondary,
                size: 20,
              ),
              const SizedBox(width: AppConstants.spacingSm),
              Text(
                'Fallback Audio',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: context.adaptiveTextPrimary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ),
          const SizedBox(height: AppConstants.spacingMd),
          _buildInfoRow(
            context,
            'Status',
            _fallbackInfo!.hasActiveFallback ? 'Active' : 'Inactive',
            LucideIcons.activity,
            valueColor: _fallbackInfo!.hasActiveFallback
                ? Colors.green.shade400
                : context.adaptiveTextSecondary,
          ),
          if (_fallbackInfo!.fallbackName != null) ...[
            const Divider(height: 1, color: AppColors.glassBorder),
            _buildInfoRow(
              context,
              'Output',
              _fallbackInfo!.fallbackName!,
              LucideIcons.speaker,
            ),
          ],
          const SizedBox(height: AppConstants.spacingMd),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _fallbackInfo!.hasActiveFallback
                  ? _deactivateFallback
                  : _activateFallback,
              icon: Icon(
                _fallbackInfo!.hasActiveFallback
                    ? LucideIcons.powerOff
                    : LucideIcons.power,
                size: 18,
              ),
              label: Text(
                _fallbackInfo!.hasActiveFallback
                    ? 'Deactivate Fallback'
                    : 'Activate Fallback',
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _fallbackInfo!.hasActiveFallback
                    ? Colors.red.shade400
                    : AppColors.accent,
                foregroundColor: _fallbackInfo!.hasActiveFallback
                    ? Colors.white
                    : Colors.black,
                padding: const EdgeInsets.symmetric(
                  vertical: AppConstants.spacingMd,
                ),
              ),
            ),
          ),
          if (!_fallbackInfo!.hasActiveFallback) ...[
            const SizedBox(height: AppConstants.spacingSm),
            Text(
              'Fallback audio will be used if UAC2 device fails',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.adaptiveTextTertiary,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInfoRow(
    BuildContext context,
    String label,
    String value,
    IconData icon, {
    Color? valueColor,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppConstants.spacingSm),
      child: Row(
        children: [
          Icon(
            icon,
            color: context.adaptiveTextSecondary,
            size: 18,
          ),
          const SizedBox(width: AppConstants.spacingMd),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: context.adaptiveTextSecondary,
                  ),
            ),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: valueColor ?? context.adaptiveTextPrimary,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}
