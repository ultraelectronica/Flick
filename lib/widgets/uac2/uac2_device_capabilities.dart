import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/services/uac2_service.dart';

class Uac2DeviceCapabilities extends ConsumerWidget {
  final Uac2DeviceInfo device;

  const Uac2DeviceCapabilities({
    required this.device,
    super.key,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final capabilitiesAsync = ref.watch(
      uac2DeviceCapabilitiesProvider(device),
    );

    return capabilitiesAsync.when(
      data: (capabilities) {
        if (capabilities == null) {
          return const Card(
            child: Padding(
              padding: EdgeInsets.all(16.0),
              child: Text('Capabilities not available'),
            ),
          );
        }

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Device Capabilities',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 16),
                _buildCapabilityRow(
                  context,
                  'Device Type',
                  capabilities.deviceType,
                  Icons.category,
                ),
                const Divider(),
                _buildCapabilityRow(
                  context,
                  'Sample Rates',
                  capabilities.supportedSampleRates
                      .map((r) => '${r ~/ 1000}kHz')
                      .join(', '),
                  Icons.graphic_eq,
                ),
                const Divider(),
                _buildCapabilityRow(
                  context,
                  'Bit Depths',
                  capabilities.supportedBitDepths
                      .map((d) => '${d}bit')
                      .join(', '),
                  Icons.high_quality,
                ),
                const Divider(),
                _buildCapabilityRow(
                  context,
                  'Channels',
                  capabilities.supportedChannels
                      .map((c) => c == 1 ? 'Mono' : c == 2 ? 'Stereo' : '$c ch')
                      .join(', '),
                  Icons.surround_sound,
                ),
              ],
            ),
          ),
        );
      },
      loading: () => const Card(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (error, stack) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text('Error loading capabilities: $error'),
        ),
      ),
    );
  }

  Widget _buildCapabilityRow(
    BuildContext context,
    String label,
    String value,
    IconData icon,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withOpacity(0.6),
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
