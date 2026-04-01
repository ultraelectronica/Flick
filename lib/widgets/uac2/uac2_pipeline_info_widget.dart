import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/services/uac2_service.dart';
import 'package:flick/src/rust/api/uac2_api.dart' as rust_uac2;

class Uac2PipelineInfoWidget extends ConsumerStatefulWidget {
  const Uac2PipelineInfoWidget({super.key});

  @override
  ConsumerState<Uac2PipelineInfoWidget> createState() =>
      _Uac2PipelineInfoWidgetState();
}

class _Uac2PipelineInfoWidgetState
    extends ConsumerState<Uac2PipelineInfoWidget> {
  rust_uac2.Uac2PipelineInfo? _pipelineInfo;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadPipelineInfo();
  }

  Future<void> _loadPipelineInfo() async {
    final service = ref.read(uac2ServiceProvider);
    final info = await service.getPipelineInfo();

    if (mounted) {
      setState(() {
        _pipelineInfo = info;
        _loading = false;
      });
    }
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

    if (_pipelineInfo == null) {
      return const SizedBox.shrink();
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
                LucideIcons.gitBranch,
                color: context.adaptiveTextSecondary,
                size: 20,
              ),
              const SizedBox(width: AppConstants.spacingSm),
              Text(
                'Audio Pipeline',
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
            'Bit-Perfect',
            _pipelineInfo!.isBitPerfect ? 'Yes' : 'No',
            LucideIcons.check,
            valueColor: _pipelineInfo!.isBitPerfect
                ? Colors.green.shade400
                : Colors.orange.shade400,
          ),
          const Divider(height: 1, color: AppColors.glassBorder),
          _buildInfoRow(
            context,
            'Conversion',
            _pipelineInfo!.requiresConversion ? 'Required' : 'None',
            LucideIcons.repeat,
            valueColor: _pipelineInfo!.requiresConversion
                ? Colors.orange.shade400
                : Colors.green.shade400,
          ),
          const Divider(height: 1, color: AppColors.glassBorder),
          _buildInfoRow(
            context,
            'Converter Type',
            _pipelineInfo!.converterType,
            LucideIcons.settings,
          ),
          if (_pipelineInfo!.isBitPerfect) ...[
            const SizedBox(height: AppConstants.spacingMd),
            Container(
              padding: const EdgeInsets.all(AppConstants.spacingSm),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(AppConstants.radiusSm),
                border: Border.all(color: Colors.green.shade400),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.verified,
                    color: Colors.green.shade400,
                    size: 18,
                  ),
                  const SizedBox(width: AppConstants.spacingSm),
                  Expanded(
                    child: Text(
                      'Audio is transmitted without modification',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.green.shade400,
                            fontWeight: FontWeight.w500,
                          ),
                    ),
                  ),
                ],
              ),
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
