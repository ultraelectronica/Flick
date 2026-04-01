import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/services/uac2_service.dart';
import 'package:flick/src/rust/api/uac2_api.dart' as rust_uac2;

class Uac2ConnectionManager extends ConsumerStatefulWidget {
  const Uac2ConnectionManager({super.key});

  @override
  ConsumerState<Uac2ConnectionManager> createState() =>
      _Uac2ConnectionManagerState();
}

class _Uac2ConnectionManagerState extends ConsumerState<Uac2ConnectionManager> {
  Timer? _updateTimer;
  rust_uac2.Uac2ConnectionState? _connectionState;
  bool _autoReconnect = false;

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
      _loadConnectionState();
    });
    _loadConnectionState();
  }

  Future<void> _loadConnectionState() async {
    final service = ref.read(uac2ServiceProvider);
    final state = await service.getConnectionState();

    if (mounted && state != null) {
      setState(() {
        _connectionState = state;
        _autoReconnect = state.autoReconnectEnabled;
      });
    }
  }

  Future<void> _toggleAutoReconnect(bool value) async {
    final service = ref.read(uac2ServiceProvider);
    final success = await service.setAutoReconnect(value);
    if (success) {
      setState(() => _autoReconnect = value);
    }
  }

  Future<void> _attemptReconnect() async {
    final service = ref.read(uac2ServiceProvider);
    final success = await service.attemptReconnect();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success ? 'Reconnection successful' : 'Reconnection failed',
          ),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }

    await _loadConnectionState();
  }

  @override
  Widget build(BuildContext context) {
    final deviceStatus = ref.watch(uac2DeviceStatusProvider);

    if (deviceStatus == null) {
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
                LucideIcons.link,
                color: context.adaptiveTextSecondary,
                size: 20,
              ),
              const SizedBox(width: AppConstants.spacingSm),
              Text(
                'Connection Management',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: context.adaptiveTextPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppConstants.spacingMd),
          if (_connectionState != null) ...[
            _buildInfoRow(
              context,
              'State',
              _connectionState!.state,
              LucideIcons.activity,
              valueColor: _getStateColor(_connectionState!.state),
            ),
            const Divider(height: 1, color: AppColors.glassBorder),
            _buildInfoRow(
              context,
              'Reconnect Attempts',
              _connectionState!.reconnectAttempts.toString(),
              LucideIcons.rotateCw,
              valueColor: _connectionState!.reconnectAttempts > 0
                  ? Colors.orange.shade400
                  : context.adaptiveTextPrimary,
            ),
            const Divider(height: 1, color: AppColors.glassBorder),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(
              vertical: AppConstants.spacingSm,
            ),
            child: Row(
              children: [
                Icon(
                  LucideIcons.repeat,
                  color: context.adaptiveTextSecondary,
                  size: 18,
                ),
                const SizedBox(width: AppConstants.spacingMd),
                Expanded(
                  child: Text(
                    'Auto-Reconnect',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: context.adaptiveTextSecondary,
                    ),
                  ),
                ),
                Switch(
                  value: _autoReconnect,
                  onChanged: _toggleAutoReconnect,
                  activeThumbColor: AppColors.accent,
                ),
              ],
            ),
          ),
          if (deviceStatus.state == Uac2State.error ||
              deviceStatus.state == Uac2State.idle) ...[
            const SizedBox(height: AppConstants.spacingSm),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _attemptReconnect,
                icon: const Icon(LucideIcons.refreshCw, size: 18),
                label: const Text('Reconnect Now'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(
                    vertical: AppConstants.spacingMd,
                  ),
                ),
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

  Color _getStateColor(String state) {
    switch (state.toLowerCase()) {
      case 'connected':
        return Colors.green.shade400;
      case 'connecting':
      case 'reconnecting':
        return Colors.orange.shade400;
      case 'disconnected':
        return context.adaptiveTextSecondary;
      case 'failed':
        return Colors.red.shade400;
      default:
        return context.adaptiveTextPrimary;
    }
  }
}
