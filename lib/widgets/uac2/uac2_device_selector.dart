import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/services/uac2_service.dart';

class Uac2DeviceSelector extends ConsumerWidget {
  const Uac2DeviceSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAvailable = ref.watch(uac2AvailableProvider);
    final devicesAsync = ref.watch(uac2DevicesProvider);
    final selectedDevice = ref.watch(selectedUac2DeviceProvider);
    final deviceStatus = ref.watch(uac2DeviceStatusProvider);

    if (!isAvailable) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: Text('UAC2 not available on this platform'),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.usb),
                const SizedBox(width: 8),
                const Text(
                  'USB Audio Device',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                if (deviceStatus != null)
                  _buildStatusIndicator(deviceStatus.state),
              ],
            ),
            const SizedBox(height: 16),
            devicesAsync.when(
              data: (devices) {
                if (devices.isEmpty) {
                  return const Text('No USB audio devices found');
                }
                return Column(
                  children: [
                    DropdownButtonFormField<Uac2DeviceInfo>(
                      initialValue: selectedDevice,
                      decoration: const InputDecoration(
                        labelText: 'Select Device',
                        border: OutlineInputBorder(),
                      ),
                      items: devices.map((device) {
                        return DropdownMenuItem(
                          value: device,
                          child: Text(
                            '${device.manufacturer} ${device.productName}',
                          ),
                        );
                      }).toList(),
                      onChanged: (device) {
                        if (device != null) {
                          ref
                              .read(selectedUac2DeviceProvider.notifier)
                              .select(device);
                        }
                      },
                    ),
                    if (selectedDevice != null) ...[
                      const SizedBox(height: 16),
                      _buildDeviceActions(context, ref, selectedDevice),
                    ],
                  ],
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stack) => Text('Error: $error'),
            ),
            if (deviceStatus?.errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                'Error: ${deviceStatus!.errorMessage}',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIndicator(Uac2State state) {
    Color color;
    String label;

    switch (state) {
      case Uac2State.idle:
        color = Colors.grey;
        label = 'Idle';
        break;
      case Uac2State.connecting:
        color = Colors.orange;
        label = 'Connecting';
        break;
      case Uac2State.connected:
        color = Colors.blue;
        label = 'Connected';
        break;
      case Uac2State.streaming:
        color = Colors.green;
        label = 'Streaming';
        break;
      case Uac2State.error:
        color = Colors.red;
        label = 'Error';
        break;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: color, fontSize: 12)),
      ],
    );
  }

  Widget _buildDeviceActions(
    BuildContext context,
    WidgetRef ref,
    Uac2DeviceInfo device,
  ) {
    final deviceStatus = ref.watch(uac2DeviceStatusProvider);
    final isConnected = deviceStatus?.state == Uac2State.connected ||
        deviceStatus?.state == Uac2State.streaming;

    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: isConnected
                ? () async {
                    await ref.read(uac2DeviceStatusProvider.notifier).disconnect();
                  }
                : () async {
                    await ref.read(uac2DeviceStatusProvider.notifier).selectDevice(device);
                  },
            icon: Icon(isConnected ? Icons.link_off : Icons.link),
            label: Text(isConnected ? 'Disconnect' : 'Connect'),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: () {
            ref.invalidate(uac2DevicesProvider);
          },
          tooltip: 'Refresh devices',
        ),
      ],
    );
  }
}
