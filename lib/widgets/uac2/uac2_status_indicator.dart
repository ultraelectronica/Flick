import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/services/uac2_service.dart';

class Uac2StatusIndicator extends ConsumerWidget {
  const Uac2StatusIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final deviceStatus = ref.watch(uac2DeviceStatusProvider);
    final isBitPerfect = ref.watch(uac2BitPerfectIndicatorProvider);
    final warningMessage = deviceStatus?.warningMessage;

    if (deviceStatus == null || deviceStatus.state == Uac2State.idle) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: _getStatusColor(deviceStatus.state).withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _getStatusColor(deviceStatus.state),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.usb, size: 16, color: _getStatusColor(deviceStatus.state)),
          const SizedBox(width: 4),
          Text(
            deviceStatus.device.productName,
            style: TextStyle(
              fontSize: 12,
              color: _getStatusColor(deviceStatus.state),
              fontWeight: FontWeight.w500,
            ),
          ),
          if (deviceStatus.currentFormat != null) ...[
            const SizedBox(width: 4),
            Text(
              '${deviceStatus.currentFormat!.sampleRate ~/ 1000}kHz/${deviceStatus.currentFormat!.bitDepth}bit',
              style: TextStyle(
                fontSize: 10,
                color: _getStatusColor(
                  deviceStatus.state,
                ).withValues(alpha: 0.8),
              ),
            ),
          ],
          if (isBitPerfect) ...[
            const SizedBox(width: 4),
            Icon(
              Icons.verified,
              size: 14,
              color: _getStatusColor(deviceStatus.state),
            ),
          ] else if (warningMessage != null) ...[
            const SizedBox(width: 4),
            Icon(Icons.info_outline, size: 14, color: Colors.amber.shade400),
          ],
        ],
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
}
