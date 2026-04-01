import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/services/uac2_service.dart';

class Uac2ErrorNotification extends ConsumerStatefulWidget {
  const Uac2ErrorNotification({super.key});

  @override
  ConsumerState<Uac2ErrorNotification> createState() =>
      _Uac2ErrorNotificationState();
}

class _Uac2ErrorNotificationState
    extends ConsumerState<Uac2ErrorNotification> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    final deviceStatus = ref.watch(uac2DeviceStatusProvider);

    if (_dismissed ||
        deviceStatus == null ||
        deviceStatus.state != Uac2State.error ||
        deviceStatus.errorMessage == null) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.shade900.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.red.shade400.withValues(alpha: 0.5),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline,
            color: Colors.red.shade400,
            size: 24,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'USB Audio Error',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.red.shade400,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  deviceStatus.errorMessage!,
                  style: TextStyle(
                    fontSize: 12,
                    color: context.adaptiveTextSecondary,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.close,
              color: context.adaptiveTextSecondary,
              size: 20,
            ),
            onPressed: () {
              setState(() {
                _dismissed = true;
              });
            },
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}
