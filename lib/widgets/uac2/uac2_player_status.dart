import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/services/uac2_service.dart';

class Uac2PlayerStatus extends ConsumerWidget {
  final bool compact;
  final bool showDeviceName;
  final bool showFormat;
  final bool showBitPerfect;

  const Uac2PlayerStatus({
    super.key,
    this.compact = false,
    this.showDeviceName = true,
    this.showFormat = true,
    this.showBitPerfect = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final deviceStatus = ref.watch(uac2DeviceStatusProvider);
    final isBitPerfect = ref.watch(uac2BitPerfectIndicatorProvider);

    if (deviceStatus == null || deviceStatus.state == Uac2State.idle) {
      return const SizedBox.shrink();
    }

    if (compact) {
      return _buildCompactStatus(context, deviceStatus, isBitPerfect);
    }

    return _buildFullStatus(context, deviceStatus, isBitPerfect);
  }

  Widget _buildCompactStatus(
    BuildContext context,
    Uac2DeviceStatus status,
    bool isBitPerfect,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: _getStatusColor(status.state).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _getStatusColor(status.state).withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.usb, size: 14, color: _getStatusColor(status.state)),
          if (status.currentFormat != null && showFormat) ...[
            const SizedBox(width: 4),
            Text(
              '${status.currentFormat!.sampleRate ~/ 1000}kHz/${status.currentFormat!.bitDepth}bit',
              style: TextStyle(
                fontSize: 10,
                color: _getStatusColor(status.state),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (isBitPerfect && showBitPerfect) ...[
            const SizedBox(width: 4),
            Icon(
              Icons.verified,
              size: 12,
              color: _getStatusColor(status.state),
            ),
          ] else if (status.warningMessage != null) ...[
            const SizedBox(width: 4),
            Icon(Icons.info_outline, size: 12, color: Colors.amber.shade400),
          ],
        ],
      ),
    );
  }

  Widget _buildFullStatus(
    BuildContext context,
    Uac2DeviceStatus status,
    bool isBitPerfect,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.glassBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _getStatusColor(status.state).withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: _getStatusColor(status.state).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  Icons.usb,
                  size: 16,
                  color: _getStatusColor(status.state),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (showDeviceName)
                      Text(
                        status.device.productName,
                        style: TextStyle(
                          fontSize: 12,
                          color: context.adaptiveTextPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: _getStatusColor(status.state),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _getStatusLabel(status.state),
                          style: TextStyle(
                            fontSize: 10,
                            color: _getStatusColor(status.state),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (status.currentFormat != null && showFormat) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildFormatBadge(
                  '${status.currentFormat!.sampleRate ~/ 1000}kHz',
                  context,
                ),
                const SizedBox(width: 4),
                _buildFormatBadge(
                  '${status.currentFormat!.bitDepth}bit',
                  context,
                ),
                const SizedBox(width: 4),
                _buildFormatBadge(
                  status.currentFormat!.channels == 1
                      ? 'Mono'
                      : status.currentFormat!.channels == 2
                      ? 'Stereo'
                      : '${status.currentFormat!.channels}ch',
                  context,
                ),
                if (isBitPerfect && showBitPerfect) ...[
                  const SizedBox(width: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.verified,
                          size: 10,
                          color: Colors.green.shade400,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          'Bit-Perfect',
                          style: TextStyle(
                            fontSize: 9,
                            color: Colors.green.shade400,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ],
          if (status.warningMessage != null) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 12,
                  color: Colors.amber.shade400,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    status.warningMessage!,
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.amber.shade400,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
          if (status.errorMessage != null) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 12,
                  color: Colors.red.shade400,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    status.errorMessage!,
                    style: TextStyle(fontSize: 10, color: Colors.red.shade400),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFormatBadge(String label, BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.glassBackgroundStrong,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.glassBorder, width: 0.5),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          color: context.adaptiveTextSecondary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
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
