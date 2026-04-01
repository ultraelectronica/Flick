import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/services/uac2_service.dart';

class Uac2VolumeControl extends ConsumerStatefulWidget {
  const Uac2VolumeControl({super.key});

  @override
  ConsumerState<Uac2VolumeControl> createState() => _Uac2VolumeControlState();
}

class _Uac2VolumeControlState extends ConsumerState<Uac2VolumeControl> {
  bool _muteUpdateInFlight = false;
  /// Volume level to restore when unmuting via button.
  double _preMuteVolume = 1.0;

  Future<void> _setVolume(double volume) async {
    final notifier = ref.read(uac2DeviceStatusProvider.notifier);
    final wasMuted = ref.read(uac2DeviceStatusProvider)?.muted ?? false;

    // Dragging above 0 while muted → auto-unmute
    if (wasMuted && volume > 0.0) {
      await notifier.setMute(false);
    }
    // Dragging to 0 → auto-mute
    if (!wasMuted && volume == 0.0) {
      _preMuteVolume = ref.read(uac2DeviceStatusProvider)?.volume ?? 1.0;
      await notifier.setMute(true);
    }
    await notifier.setVolume(volume);
  }

  Future<void> _toggleMute() async {
    final notifier = ref.read(uac2DeviceStatusProvider.notifier);
    final currentMuted = ref.read(uac2DeviceStatusProvider)?.muted ?? false;
    final newMuted = !currentMuted;

    setState(() => _muteUpdateInFlight = true);

    if (newMuted) {
      // Muting: save current volume for restore, then mute + set volume to 0
      _preMuteVolume = (ref.read(uac2DeviceStatusProvider)?.volume ?? 1.0).clamp(0.01, 1.0);
      final success = await notifier.setMute(true);
      if (success) await notifier.setVolume(0.0);
    } else {
      // Unmuting: restore pre-mute volume, then unmute
      await notifier.setVolume(_preMuteVolume);
      await notifier.setMute(false);
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

    final effectiveVolume = deviceStatus.volume ?? 1.0;
    final effectiveMuted = deviceStatus.muted ?? false;

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
                onPressed: _muteUpdateInFlight ? null : _toggleMute,
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
                  label: '${(effectiveVolume * 100).round()}%',
                  onChanged: _setVolume,
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
                width: 40,
                child: Text(
                  '${(effectiveVolume * 100).round()}%',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.adaptiveTextSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
