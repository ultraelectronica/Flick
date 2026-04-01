import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/services/uac2_service.dart';

class Uac2StreamConfig extends ConsumerStatefulWidget {
  final Uac2DeviceInfo device;

  const Uac2StreamConfig({
    required this.device,
    super.key,
  });

  @override
  ConsumerState<Uac2StreamConfig> createState() => _Uac2StreamConfigState();
}

class _Uac2StreamConfigState extends ConsumerState<Uac2StreamConfig> {
  int _selectedSampleRate = 48000;
  int _selectedBitDepth = 24;
  int _selectedChannels = 2;

  @override
  Widget build(BuildContext context) {
    final capabilitiesAsync = ref.watch(
      uac2DeviceCapabilitiesProvider(widget.device),
    );
    final deviceStatus = ref.watch(uac2DeviceStatusProvider);
    final isStreaming = deviceStatus?.state == Uac2State.streaming;

    return capabilitiesAsync.when(
      data: (capabilities) {
        if (capabilities == null) {
          return _buildUnavailable(context);
        }
        return _buildConfigContent(context, capabilities, isStreaming);
      },
      loading: () => _buildLoading(context),
      error: (error, _) => _buildError(context, error),
    );
  }

  Widget _buildUnavailable(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppConstants.spacingLg),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Text(
        'Stream configuration not available',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: context.adaptiveTextTertiary,
            ),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildLoading(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppConstants.spacingLg),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: const Center(child: CircularProgressIndicator()),
    );
  }

  Widget _buildError(BuildContext context, Object error) {
    return Container(
      padding: const EdgeInsets.all(AppConstants.spacingLg),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Text(
        'Error: $error',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.red.shade400,
            ),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildConfigContent(
    BuildContext context,
    Uac2DeviceCapabilities capabilities,
    bool isStreaming,
  ) {
    final sampleRates = capabilities.supportedSampleRates.toList()..sort();
    final bitDepths = capabilities.supportedBitDepths.toList()..sort();
    final channels = capabilities.supportedChannels.toList()..sort();

    if (sampleRates.isNotEmpty && !sampleRates.contains(_selectedSampleRate)) {
      _selectedSampleRate = sampleRates.last;
    }
    if (bitDepths.isNotEmpty && !bitDepths.contains(_selectedBitDepth)) {
      _selectedBitDepth = bitDepths.last;
    }
    if (channels.isNotEmpty && !channels.contains(_selectedChannels)) {
      _selectedChannels = channels.last;
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
          _buildConfigRow(
            context,
            'Sample Rate',
            LucideIcons.activity,
            DropdownButton<int>(
              value: _selectedSampleRate,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              items: sampleRates.map((rate) {
                return DropdownMenuItem(
                  value: rate,
                  child: Text('${rate ~/ 1000}kHz'),
                );
              }).toList(),
              onChanged: isStreaming
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _selectedSampleRate = value);
                      }
                    },
            ),
          ),
          const Divider(height: 1, color: AppColors.glassBorder),
          _buildConfigRow(
            context,
            'Bit Depth',
            LucideIcons.layers,
            DropdownButton<int>(
              value: _selectedBitDepth,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              items: bitDepths.map((depth) {
                return DropdownMenuItem(
                  value: depth,
                  child: Text('${depth}bit'),
                );
              }).toList(),
              onChanged: isStreaming
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _selectedBitDepth = value);
                      }
                    },
            ),
          ),
          const Divider(height: 1, color: AppColors.glassBorder),
          _buildConfigRow(
            context,
            'Channels',
            LucideIcons.radio,
            DropdownButton<int>(
              value: _selectedChannels,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              items: channels.map((ch) {
                return DropdownMenuItem(
                  value: ch,
                  child: Text(
                    ch == 1 ? 'Mono' : ch == 2 ? 'Stereo' : '$ch channels',
                  ),
                );
              }).toList(),
              onChanged: isStreaming
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _selectedChannels = value);
                      }
                    },
            ),
          ),
          const SizedBox(height: AppConstants.spacingMd),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: isStreaming ? _stopStreaming : _startStreaming,
              icon: Icon(
                isStreaming ? LucideIcons.square : LucideIcons.play,
                size: 18,
              ),
              label: Text(isStreaming ? 'Stop Streaming' : 'Start Streaming'),
              style: ElevatedButton.styleFrom(
                backgroundColor: isStreaming
                    ? Colors.red.shade400
                    : AppColors.accent,
                foregroundColor: isStreaming ? Colors.white : Colors.black,
                padding: const EdgeInsets.symmetric(
                  vertical: AppConstants.spacingMd,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConfigRow(
    BuildContext context,
    String label,
    IconData icon,
    Widget control,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppConstants.spacingSm),
      child: Row(
        children: [
          Icon(
            icon,
            color: context.adaptiveTextSecondary,
            size: 20,
          ),
          const SizedBox(width: AppConstants.spacingMd),
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: context.adaptiveTextPrimary,
                  ),
            ),
          ),
          Expanded(
            flex: 3,
            child: control,
          ),
        ],
      ),
    );
  }

  Future<void> _startStreaming() async {
    final deviceStatusNotifier = ref.read(uac2DeviceStatusProvider.notifier);
    final format = Uac2AudioFormat(
      sampleRate: _selectedSampleRate,
      bitDepth: _selectedBitDepth,
      channels: _selectedChannels,
    );

    final success = await deviceStatusNotifier.startStreaming(format);
    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to start streaming'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _stopStreaming() async {
    final deviceStatusNotifier = ref.read(uac2DeviceStatusProvider.notifier);
    final success = await deviceStatusNotifier.stopStreaming();
    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to stop streaming'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}
