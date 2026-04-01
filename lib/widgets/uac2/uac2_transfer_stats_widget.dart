import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/services/uac2_service.dart';
import 'package:flick/src/rust/api/uac2_api.dart' as rust_uac2;

class Uac2TransferStatsWidget extends ConsumerStatefulWidget {
  const Uac2TransferStatsWidget({super.key});

  @override
  ConsumerState<Uac2TransferStatsWidget> createState() =>
      _Uac2TransferStatsWidgetState();
}

class _Uac2TransferStatsWidgetState
    extends ConsumerState<Uac2TransferStatsWidget> {
  Timer? _updateTimer;
  rust_uac2.Uac2TransferStats? _stats;
  bool _loading = true;
  String? _unavailableMessage;

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

  Future<void> _startUpdating() async {
    await _loadStats();
    if (!mounted) return;

    final service = ref.read(uac2ServiceProvider);
    if (!service.supportsTransferStats) {
      return;
    }

    _updateTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _loadStats();
    });
  }

  Future<void> _loadStats() async {
    final service = ref.read(uac2ServiceProvider);
    final stats = await service.getTransferStats();

    if (!mounted) return;

    setState(() {
      _stats = stats;
      _loading = false;
      _unavailableMessage = stats == null
          ? _buildUnavailableMessage(service)
          : null;
    });
  }

  Future<void> _resetStats() async {
    final service = ref.read(uac2ServiceProvider);
    if (!service.supportsTransferStats) {
      return;
    }

    await service.resetTransferStats();
    await _loadStats();
  }

  @override
  Widget build(BuildContext context) {
    final deviceStatus = ref.watch(uac2DeviceStatusProvider);

    if (deviceStatus == null || deviceStatus.state != Uac2State.streaming) {
      return const SizedBox.shrink();
    }

    if (_loading) {
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

    if (_stats == null) {
      return _buildUnavailable(context);
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
                LucideIcons.activity,
                color: context.adaptiveTextSecondary,
                size: 20,
              ),
              const SizedBox(width: AppConstants.spacingSm),
              Text(
                'Transfer Statistics',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: context.adaptiveTextPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(LucideIcons.refreshCw, size: 18),
                onPressed: _resetStats,
                color: context.adaptiveTextSecondary,
                tooltip: 'Reset Statistics',
              ),
            ],
          ),
          const SizedBox(height: AppConstants.spacingMd),
          _buildStatRow(
            context,
            'Submitted',
            _stats!.totalSubmitted.toString(),
            LucideIcons.upload,
          ),
          const Divider(height: 1, color: AppColors.glassBorder),
          _buildStatRow(
            context,
            'Completed',
            _stats!.totalCompleted.toString(),
            LucideIcons.check,
            valueColor: Colors.green.shade400,
          ),
          const Divider(height: 1, color: AppColors.glassBorder),
          _buildStatRow(
            context,
            'Failed',
            _stats!.totalFailed.toString(),
            LucideIcons.x,
            valueColor: _stats!.totalFailed.toInt() > 0
                ? Colors.red.shade400
                : context.adaptiveTextPrimary,
          ),
          const Divider(height: 1, color: AppColors.glassBorder),
          _buildStatRow(
            context,
            'Retried',
            _stats!.totalRetried.toString(),
            LucideIcons.rotateCw,
            valueColor: _stats!.totalRetried.toInt() > 0
                ? Colors.orange.shade400
                : context.adaptiveTextPrimary,
          ),
          const Divider(height: 1, color: AppColors.glassBorder),
          _buildStatRow(
            context,
            'Underruns',
            _stats!.underruns.toString(),
            LucideIcons.triangle,
            valueColor: _stats!.underruns.toInt() > 0
                ? Colors.orange.shade400
                : context.adaptiveTextPrimary,
          ),
          const Divider(height: 1, color: AppColors.glassBorder),
          _buildStatRow(
            context,
            'Overruns',
            _stats!.overruns.toString(),
            LucideIcons.octagon,
            valueColor: _stats!.overruns.toInt() > 0
                ? Colors.red.shade400
                : context.adaptiveTextPrimary,
          ),
          const Divider(height: 1, color: AppColors.glassBorder),
          _buildStatRow(
            context,
            'Success Rate',
            '${(_stats!.successRate * 100).toStringAsFixed(1)}%',
            LucideIcons.trendingUp,
            valueColor: _getSuccessRateColor(_stats!.successRate),
          ),
        ],
      ),
    );
  }

  Widget _buildStatRow(
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
          Icon(icon, color: context.adaptiveTextSecondary, size: 18),
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

  Color _getSuccessRateColor(double rate) {
    if (rate >= 0.99) return Colors.green.shade400;
    if (rate >= 0.95) return Colors.orange.shade400;
    return Colors.red.shade400;
  }

  Widget _buildUnavailable(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppConstants.spacingLg),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Row(
        children: [
          Icon(
            LucideIcons.info,
            color: context.adaptiveTextSecondary,
            size: 20,
          ),
          const SizedBox(width: AppConstants.spacingMd),
          Expanded(
            child: Text(
              _unavailableMessage ?? 'Transfer statistics unavailable',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: context.adaptiveTextTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _buildUnavailableMessage(Uac2Service service) {
    if (!service.supportsTransferStats) {
      if (kIsWeb) {
        return 'Transfer statistics are not available on this platform.';
      }

      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          return 'Transfer statistics are not available on Android yet.';
        case TargetPlatform.iOS:
        case TargetPlatform.fuchsia:
        case TargetPlatform.linux:
        case TargetPlatform.macOS:
        case TargetPlatform.windows:
          return 'Transfer statistics are not available on this platform.';
      }
    }

    return 'Transfer statistics are currently unavailable.';
  }
}
