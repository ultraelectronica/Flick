import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/services/uac2_service.dart';
import 'package:flick/widgets/common/display_mode_wrapper.dart';
import 'package:flick/features/settings/screens/uac2_preferences_screen.dart';
import 'package:flick/widgets/uac2/uac2_volume_control.dart';
import 'package:flick/widgets/uac2/uac2_stream_config.dart';
import 'package:flick/widgets/uac2/uac2_hotplug_monitor.dart';
import 'package:flick/widgets/uac2/uac2_transfer_stats_widget.dart';
import 'package:flick/widgets/uac2/uac2_pipeline_info_widget.dart';
import 'package:flick/widgets/uac2/uac2_connection_manager.dart';
import 'package:flick/widgets/uac2/uac2_fallback_manager.dart';

class Uac2SettingsScreen extends ConsumerStatefulWidget {
  const Uac2SettingsScreen({super.key});

  @override
  ConsumerState<Uac2SettingsScreen> createState() => _Uac2SettingsScreenState();
}

class _Uac2SettingsScreenState extends ConsumerState<Uac2SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final isAvailable = ref.watch(uac2AvailableProvider);
    final devicesAsync = ref.watch(uac2DevicesProvider);
    final selectedDevice = ref.watch(selectedUac2DeviceProvider);
    final deviceStatusNotifier = ref.watch(uac2DeviceStatusProvider);
    final deviceStatus = deviceStatusNotifier.status;

    return DisplayModeWrapper(
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(context),
              const SizedBox(height: AppConstants.spacingMd),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppConstants.spacingMd,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!isAvailable) _buildUnavailableCard(context),
                      if (isAvailable) ...[
                        const Uac2HotplugMonitor(),
                        _buildSectionHeader(context, 'USB Audio Devices'),
                        devicesAsync.when(
                          data: (devices) => _buildDevicesList(
                            context,
                            devices,
                            selectedDevice,
                            deviceStatus,
                          ),
                          loading: () => _buildLoadingCard(context),
                          error: (error, _) => _buildErrorCard(context, error),
                        ),
                        if (selectedDevice != null) ...[
                          const SizedBox(height: AppConstants.spacingLg),
                          _buildSectionHeader(context, 'Device Information'),
                          _buildDeviceInfoCard(context, selectedDevice),
                          const SizedBox(height: AppConstants.spacingLg),
                          _buildSectionHeader(context, 'Capabilities'),
                          _buildCapabilitiesCard(context, selectedDevice),
                          const SizedBox(height: AppConstants.spacingLg),
                          _buildSectionHeader(context, 'Stream Configuration'),
                          Uac2StreamConfig(device: selectedDevice),
                          const SizedBox(height: AppConstants.spacingLg),
                          _buildSectionHeader(context, 'Connection Management'),
                          const Uac2ConnectionManager(),
                          const SizedBox(height: AppConstants.spacingLg),
                          _buildSectionHeader(context, 'Fallback Audio'),
                          const Uac2FallbackManager(),
                        ],
                        if (deviceStatus != null) ...[
                          const SizedBox(height: AppConstants.spacingLg),
                          _buildSectionHeader(context, 'Status'),
                          _buildStatusCard(context, deviceStatus),
                        ],
                        if (deviceStatus?.state == Uac2State.streaming) ...[
                          const SizedBox(height: AppConstants.spacingLg),
                          _buildSectionHeader(context, 'Volume Control'),
                          const Uac2VolumeControl(),
                          const SizedBox(height: AppConstants.spacingLg),
                          _buildSectionHeader(context, 'Pipeline Information'),
                          const Uac2PipelineInfoWidget(),
                          const SizedBox(height: AppConstants.spacingLg),
                          _buildSectionHeader(context, 'Transfer Statistics'),
                          const Uac2TransferStatsWidget(),
                        ],
                      ],
                      const SizedBox(height: AppConstants.navBarHeight + 120),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppConstants.spacingLg,
        vertical: AppConstants.spacingMd,
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(LucideIcons.arrowLeft),
            onPressed: () => Navigator.of(context).pop(),
            color: context.adaptiveTextPrimary,
          ),
          const SizedBox(width: AppConstants.spacingSm),
          Expanded(
            child: Text(
              'USB Audio (UAC2)',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: context.adaptiveTextPrimary,
                  ),
            ),
          ),
          IconButton(
            icon: const Icon(LucideIcons.settings),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const Uac2PreferencesScreen(),
                ),
              );
            },
            color: context.adaptiveTextPrimary,
            tooltip: 'Preferences',
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(
        left: AppConstants.spacingXs,
        bottom: AppConstants.spacingSm,
      ),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: context.adaptiveTextTertiary,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }

  Widget _buildUnavailableCard(BuildContext context) {
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
            Icons.info_outline,
            color: context.adaptiveTextSecondary,
            size: 24,
          ),
          const SizedBox(width: AppConstants.spacingMd),
          Expanded(
            child: Text(
              'UAC2 is not available on this platform',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: context.adaptiveTextSecondary,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingCard(BuildContext context) {
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

  Widget _buildErrorCard(BuildContext context, Object error) {
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
            Icons.error_outline,
            color: Colors.red.shade400,
            size: 24,
          ),
          const SizedBox(width: AppConstants.spacingMd),
          Expanded(
            child: Text(
              'Error: $error',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.red.shade400,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDevicesList(
    BuildContext context,
    List<Uac2DeviceInfo> devices,
    Uac2DeviceInfo? selectedDevice,
    Uac2DeviceStatus? deviceStatus,
  ) {
    if (devices.isEmpty) {
      return _buildNoDevicesCard(context);
    }

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Column(
        children: [
          ...devices.asMap().entries.map((entry) {
            final index = entry.key;
            final device = entry.value;
            final isSelected = selectedDevice?.vendorId == device.vendorId &&
                selectedDevice?.productId == device.productId &&
                selectedDevice?.serial == device.serial;
            return Column(
              children: [
                _buildDeviceItem(
                  context,
                  device,
                  isSelected,
                  deviceStatus,
                ),
                if (index < devices.length - 1) _buildDivider(),
              ],
            );
          }),
          _buildDivider(),
          _buildRefreshButton(context),
        ],
      ),
    );
  }

  Widget _buildNoDevicesCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppConstants.spacingLg),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Column(
        children: [
          Icon(
            Icons.usb_off,
            color: context.adaptiveTextTertiary,
            size: 48,
          ),
          const SizedBox(height: AppConstants.spacingMd),
          Text(
            'No USB audio devices found',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: context.adaptiveTextSecondary,
                ),
          ),
          const SizedBox(height: AppConstants.spacingSm),
          Text(
            'Connect a USB DAC or audio interface',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: context.adaptiveTextTertiary,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppConstants.spacingLg),
          _buildRefreshButton(context),
        ],
      ),
    );
  }

  Widget _buildDeviceItem(
    BuildContext context,
    Uac2DeviceInfo device,
    bool isSelected,
    Uac2DeviceStatus? deviceStatus,
  ) {
    final isConnected = isSelected &&
        (deviceStatus?.state == Uac2State.connected ||
            deviceStatus?.state == Uac2State.streaming);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _handleDeviceSelection(device, isSelected, isConnected),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        child: Padding(
          padding: const EdgeInsets.all(AppConstants.spacingMd),
          child: Row(
            children: [
              Container(
                width: context.scaleSize(AppConstants.containerSizeSm),
                height: context.scaleSize(AppConstants.containerSizeSm),
                decoration: BoxDecoration(
                  color: isSelected
                      ? AppColors.glassBackgroundStrong
                      : AppColors.glassBackground,
                  borderRadius: BorderRadius.circular(AppConstants.radiusSm),
                ),
                child: Icon(
                  LucideIcons.usb,
                  color: isSelected
                      ? AppColors.textPrimary
                      : AppColors.textSecondary,
                  size: context.responsiveIcon(AppConstants.iconSizeMd),
                ),
              ),
              const SizedBox(width: AppConstants.spacingMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${device.manufacturer} ${device.productName}',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: context.adaptiveTextPrimary,
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'VID: 0x${device.vendorId.toRadixString(16).padLeft(4, '0')} '
                      'PID: 0x${device.productId.toRadixString(16).padLeft(4, '0')}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: context.adaptiveTextTertiary,
                          ),
                    ),
                  ],
                ),
              ),
              if (isSelected) ...[
                if (isConnected)
                  _buildStatusBadge(context, deviceStatus!.state)
                else
                  Icon(
                    LucideIcons.check,
                    color: context.adaptiveTextPrimary,
                    size: 20,
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBadge(BuildContext context, Uac2State state) {
    final color = _getStatusColor(state);
    final label = _getStatusLabel(state);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppConstants.spacingSm,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(AppConstants.radiusSm),
        border: Border.all(color: color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRefreshButton(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => ref.invalidate(uac2DevicesProvider),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        child: Padding(
          padding: const EdgeInsets.all(AppConstants.spacingMd),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                LucideIcons.refreshCw,
                color: context.adaptiveTextSecondary,
                size: 18,
              ),
              const SizedBox(width: AppConstants.spacingSm),
              Text(
                'Refresh Devices',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: context.adaptiveTextSecondary,
                      fontWeight: FontWeight.w500,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceInfoCard(BuildContext context, Uac2DeviceInfo device) {
    return Container(
      padding: const EdgeInsets.all(AppConstants.spacingMd),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Column(
        children: [
          _buildInfoRow(
            context,
            'Manufacturer',
            device.manufacturer.isNotEmpty
                ? device.manufacturer
                : 'Unknown',
            LucideIcons.building,
          ),
          _buildDivider(),
          _buildInfoRow(
            context,
            'Product',
            device.productName,
            LucideIcons.package,
          ),
          _buildDivider(),
          _buildInfoRow(
            context,
            'Serial Number',
            device.serial ?? 'N/A',
            LucideIcons.hash,
          ),
          _buildDivider(),
          _buildInfoRow(
            context,
            'Vendor ID',
            '0x${device.vendorId.toRadixString(16).toUpperCase().padLeft(4, '0')}',
            LucideIcons.tag,
          ),
          _buildDivider(),
          _buildInfoRow(
            context,
            'Product ID',
            '0x${device.productId.toRadixString(16).toUpperCase().padLeft(4, '0')}',
            LucideIcons.tag,
          ),
        ],
      ),
    );
  }

  Widget _buildCapabilitiesCard(
    BuildContext context,
    Uac2DeviceInfo device,
  ) {
    final capabilitiesAsync = ref.watch(
      uac2DeviceCapabilitiesProvider(device),
    );

    return capabilitiesAsync.when(
      data: (capabilities) {
        if (capabilities == null) {
          return _buildCapabilitiesUnavailable(context);
        }
        return _buildCapabilitiesContent(context, capabilities);
      },
      loading: () => _buildLoadingCard(context),
      error: (error, _) => _buildErrorCard(context, error),
    );
  }

  Widget _buildCapabilitiesUnavailable(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppConstants.spacingLg),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Text(
        'Capabilities not available',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: context.adaptiveTextTertiary,
            ),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildCapabilitiesContent(
    BuildContext context,
    Uac2DeviceCapabilities capabilities,
  ) {
    return Container(
      padding: const EdgeInsets.all(AppConstants.spacingMd),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Column(
        children: [
          _buildInfoRow(
            context,
            'Device Type',
            capabilities.deviceType,
            LucideIcons.cpu,
          ),
          _buildDivider(),
          _buildInfoRow(
            context,
            'Sample Rates',
            capabilities.supportedSampleRates
                .map((r) => '${r ~/ 1000}kHz')
                .join(', '),
            LucideIcons.activity,
          ),
          _buildDivider(),
          _buildInfoRow(
            context,
            'Bit Depths',
            capabilities.supportedBitDepths.map((d) => '${d}bit').join(', '),
            LucideIcons.layers,
          ),
          _buildDivider(),
          _buildInfoRow(
            context,
            'Channels',
            capabilities.supportedChannels
                .map((c) => c == 1 ? 'Mono' : c == 2 ? 'Stereo' : '$c ch')
                .join(', '),
            LucideIcons.radio,
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard(BuildContext context, Uac2DeviceStatus status) {
    final isBitPerfect = ref.watch(uac2BitPerfectIndicatorProvider);

    return Container(
      padding: const EdgeInsets.all(AppConstants.spacingMd),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Column(
        children: [
          _buildInfoRow(
            context,
            'Connection Status',
            _getStatusLabel(status.state),
            LucideIcons.activity,
            valueColor: _getStatusColor(status.state),
          ),
          if (status.currentFormat != null) ...[
            _buildDivider(),
            _buildInfoRow(
              context,
              'Sample Rate',
              '${status.currentFormat!.sampleRate ~/ 1000}kHz',
              Icons.graphic_eq,
            ),
            _buildDivider(),
            _buildInfoRow(
              context,
              'Bit Depth',
              '${status.currentFormat!.bitDepth}bit',
              LucideIcons.layers,
            ),
            _buildDivider(),
            _buildInfoRow(
              context,
              'Channels',
              status.currentFormat!.channels == 1
                  ? 'Mono'
                  : status.currentFormat!.channels == 2
                      ? 'Stereo'
                      : '${status.currentFormat!.channels} channels',
              LucideIcons.radio,
            ),
          ],
          if (isBitPerfect) ...[
            _buildDivider(),
            _buildBitPerfectIndicator(context),
          ],
          if (status.errorMessage != null) ...[
            _buildDivider(),
            _buildErrorMessage(context, status.errorMessage!),
          ],
        ],
      ),
    );
  }

  Widget _buildBitPerfectIndicator(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppConstants.spacingSm),
      child: Row(
        children: [
          Icon(
            Icons.verified,
            color: Colors.green.shade400,
            size: 20,
          ),
          const SizedBox(width: AppConstants.spacingMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Bit-Perfect',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.green.shade400,
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Audio is being transmitted without modification',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.adaptiveTextTertiary,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorMessage(BuildContext context, String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppConstants.spacingSm),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            color: Colors.red.shade400,
            size: 20,
          ),
          const SizedBox(width: AppConstants.spacingMd),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.red.shade400,
                  ),
            ),
          ),
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
            size: 20,
          ),
          const SizedBox(width: AppConstants.spacingMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.adaptiveTextTertiary,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: valueColor ?? context.adaptiveTextPrimary,
                        fontWeight: FontWeight.w500,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDivider() {
    return const Divider(
      height: 1,
      thickness: 1,
      color: AppColors.glassBorder,
    );
  }

  void _handleDeviceSelection(
    Uac2DeviceInfo device,
    bool isSelected,
    bool isConnected,
  ) async {
    final deviceStatusNotifier = ref.read(uac2DeviceStatusProvider);

    if (isConnected) {
      await deviceStatusNotifier.disconnect();
    } else {
      ref.read(selectedUac2DeviceProvider.notifier).select(device);
      await deviceStatusNotifier.selectDevice(device);
    }
  }

  Color _getStatusColor(Uac2State state) {
    switch (state) {
      case Uac2State.idle:
        return Colors.grey;
      case Uac2State.connecting:
        return Colors.orange;
      case Uac2State.connected:
        return Colors.blue;
      case Uac2State.streaming:
        return Colors.green;
      case Uac2State.error:
        return Colors.red;
    }
  }

  String _getStatusLabel(Uac2State state) {
    switch (state) {
      case Uac2State.idle:
        return 'Idle';
      case Uac2State.connecting:
        return 'Connecting';
      case Uac2State.connected:
        return 'Connected';
      case Uac2State.streaming:
        return 'Streaming';
      case Uac2State.error:
        return 'Error';
    }
  }
}
