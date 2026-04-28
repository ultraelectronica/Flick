import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/services/uac2_service.dart';

/// Convert a linear volume (0.0–1.0) to decibels using the same
/// exponential curve as the Rust audio engine (≈ -60 dB to 0 dB).
String _volumeToDb(double volume) {
  if (volume <= 0.0) return '-∞';
  if (volume >= 1.0) return '0.0';
  final db = 60.0 * (volume - 1.0);
  return db.toStringAsFixed(1);
}

class Uac2VolumeControl extends ConsumerStatefulWidget {
  const Uac2VolumeControl({super.key});

  @override
  ConsumerState<Uac2VolumeControl> createState() => _Uac2VolumeControlState();
}

class _Uac2VolumeControlState extends ConsumerState<Uac2VolumeControl> {
  bool _muteUpdateInFlight = false;

  /// Volume level to restore when unmuting via button.
  double _preMuteVolume = 1.0;

  /// Optimistic volume while the user is dragging the slider.
  double? _draggingVolume;

  /// Called on every slider tick during drag — optimistic UI only, no platform call.
  void _onSliderChanged(double volume) {
    setState(() => _draggingVolume = volume);
  }

  /// Called when the user lifts the finger — commits the value to the platform.
  /// For software volume mode, also syncs to PlayerService so that
  /// [_currentVolume] stays in sync with the slider.
  Future<void> _onSliderChangeEnd(double volume) async {
    setState(() => _draggingVolume = null);

    final notifier = ref.read(uac2DeviceStatusProvider.notifier);
    final status = ref.read(uac2DeviceStatusProvider);
    final wasMuted = status?.muted ?? false;
    final isSoftwareVolume = status?.volumeMode == Uac2VolumeMode.software;

    if (wasMuted && volume > 0.0) {
      await notifier.setMute(false);
    }
    if (!wasMuted && volume == 0.0) {
      final currentVol = isSoftwareVolume
          ? ref.read(playerServiceProvider).currentVolume
          : (status?.volume ?? 1.0);
      _preMuteVolume = currentVol > 0.0 ? currentVol : 1.0;
      await notifier.setMute(true);
    }
    await notifier.setVolume(volume);

    if (isSoftwareVolume) {
      await ref.read(playerServiceProvider).setVolume(volume);
    }
  }

  Future<void> _toggleMute() async {
    final notifier = ref.read(uac2DeviceStatusProvider.notifier);
    final status = ref.read(uac2DeviceStatusProvider);
    final currentMuted = status?.muted ?? false;
    final newMuted = !currentMuted;
    final isSoftwareVolume = status?.volumeMode == Uac2VolumeMode.software;

    setState(() => _muteUpdateInFlight = true);

    if (newMuted) {
      _preMuteVolume = (isSoftwareVolume
              ? ref.read(playerServiceProvider).currentVolume
              : (status?.volume ?? 1.0))
          .clamp(0.01, 1.0);
      final success = await notifier.setMute(true);
      if (success) await notifier.setVolume(0.0);
      if (isSoftwareVolume) {
        await ref.read(playerServiceProvider).setVolume(0.0);
      }
    } else {
      await notifier.setVolume(_preMuteVolume);
      await notifier.setMute(false);
      if (isSoftwareVolume) {
        await ref.read(playerServiceProvider).setVolume(_preMuteVolume);
      }
    }

    if (mounted) setState(() => _muteUpdateInFlight = false);
  }

  @override
  Widget build(BuildContext context) {
    final deviceStatus = ref.watch(uac2DeviceStatusProvider);

    if (deviceStatus == null ||
        deviceStatus.state == Uac2State.idle ||
        !deviceStatus.hasVolumeControl) {
      return const SizedBox.shrink();
    }

    final isSoftwareVolume = deviceStatus.volumeMode == Uac2VolumeMode.software;
    final playerVolume = ref.read(playerServiceProvider).currentVolume;
    final effectiveVolume = _draggingVolume ??
        (isSoftwareVolume ? playerVolume : (deviceStatus.volume ?? 1.0));
    final effectiveMuted = deviceStatus.muted ?? false;
    final volumeControlWritable =
        deviceStatus.volumeControlWritable && !_muteUpdateInFlight;
    final showDb = isSoftwareVolume ||
        deviceStatus.volumeMode == Uac2VolumeMode.hardware;

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
                LucideIcons.volume2,
                color: context.adaptiveTextSecondary,
                size: 20,
              ),
              const SizedBox(width: AppConstants.spacingSm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      deviceStatus.isExternalRoute
                          ? 'USB Route Volume'
                          : 'Device DAC Volume',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: context.adaptiveTextPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if ((deviceStatus.routeLabel?.isNotEmpty ?? false))
                      Text(
                        deviceStatus.routeLabel!,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: context.adaptiveTextTertiary,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(
                  effectiveMuted ? LucideIcons.volumeX : LucideIcons.volume2,
                  size: 20,
                ),
                onPressed: volumeControlWritable ? _toggleMute : null,
                color: effectiveMuted
                    ? Colors.red.shade400
                    : context.adaptiveTextSecondary,
                tooltip: effectiveMuted ? 'Unmute' : 'Mute',
              ),
            ],
          ),
          const SizedBox(height: AppConstants.spacingSm),
          Row(
            children: [
              Icon(
                LucideIcons.volume1,
                color: context.adaptiveTextTertiary,
                size: 16,
              ),
              Expanded(
                child: Slider(
                  value: effectiveVolume,
                  min: 0.0,
                  max: 1.0,
                  divisions: 100,
                  label: showDb
                      ? '${(effectiveVolume * 100).round()}%  ${_volumeToDb(effectiveVolume)} dB'
                      : '${(effectiveVolume * 100).round()}%',
                  onChanged: volumeControlWritable ? _onSliderChanged : null,
                  onChangeEnd: volumeControlWritable
                      ? _onSliderChangeEnd
                      : null,
                  activeColor: AppColors.accent,
                  inactiveColor: AppColors.textTertiary.withValues(alpha: 0.3),
                ),
              ),
              Icon(
                LucideIcons.volume2,
                color: context.adaptiveTextTertiary,
                size: 16,
              ),
              const SizedBox(width: AppConstants.spacingSm),
              SizedBox(
                width: showDb ? 82 : 40,
                child: Text(
                  showDb
                      ? '${(effectiveVolume * 100).round()}%  ${_volumeToDb(effectiveVolume)} dB'
                      : '${(effectiveVolume * 100).round()}%',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.adaptiveTextSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          if (!deviceStatus.volumeControlWritable) ...[
            const SizedBox(height: AppConstants.spacingXs),
            Text(
              'Hardware volume is detected, but writes stay blocked while live direct USB playback is active.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: context.adaptiveTextTertiary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
