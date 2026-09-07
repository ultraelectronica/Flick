import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flick/providers/uac2_provider.dart';
import 'package:flick/services/uac2_preferences_service.dart';
import 'package:flick/services/uac2_service.dart';
import 'package:flick/widgets/common/flick_dialog.dart';

/// Pure gate: prompt only for an external USB route in a live state while
/// bit-perfect is off.
bool shouldPromptBitPerfect(
  Uac2DeviceStatus status, {
  required bool bitPerfectEnabled,
}) {
  if (bitPerfectEnabled) return false;
  if (status.routeType != Uac2RouteType.externalUsb &&
      !status.isExternalRoute) {
    return false;
  }
  return switch (status.state) {
    Uac2State.connected || Uac2State.prewarming || Uac2State.streaming => true,
    _ => false,
  };
}

/// Stable per-device identity so one DAC prompts at most once per session.
String usbDevicePromptKey(Uac2DeviceInfo device) =>
    '${device.vendorId}:${device.productId}:${device.serial ?? device.deviceName}';

/// Auto-detects a connected USB DAC and offers a one-tap switch to
/// Bit-perfect (USB DAC) mode. Renders nothing; mount once in the shell.
/// Asks once per device, ever — declines are persisted.
class UsbBitPerfectPrompt extends ConsumerStatefulWidget {
  const UsbBitPerfectPrompt({super.key});

  @override
  ConsumerState<UsbBitPerfectPrompt> createState() =>
      _UsbBitPerfectPromptState();
}

class _UsbBitPerfectPromptState extends ConsumerState<UsbBitPerfectPrompt> {
  // Race guard for bursty status events only; the persisted list in
  // Uac2PreferencesService is the real once-per-device memory.
  final Set<String> _promptedDevices = {};

  @override
  void initState() {
    super.initState();
    ref.listenManual(
      uac2DeviceStatusProvider,
      (_, next) {
        if (next != null) _maybePrompt(next);
      },
      fireImmediately: true,
    );
  }

  Future<void> _maybePrompt(Uac2DeviceStatus status) async {
    if (!mounted) return;
    if (!shouldPromptBitPerfect(
      status,
      bitPerfectEnabled: ref.read(uac2ServiceProvider).isBitPerfectEnabledSync,
    )) {
      return;
    }

    final promptKey = usbDevicePromptKey(status.device);
    if (!_promptedDevices.add(promptKey)) return;

    final preferences = ref.read(uac2PreferencesServiceProvider);
    try {
      if ((await preferences.getPromptedUsbDevices()).contains(promptKey)) {
        return;
      }
      await preferences.addPromptedUsbDevice(promptKey);
    } catch (_) {
      return;
    }

    final AudioEnginePreference engine;
    try {
      engine = await preferences.getAudioEnginePreference();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    _showPrompt(status, switchEngine: engine != AudioEnginePreference.isochronousUsb);
  }

  Future<void> _showPrompt(
    Uac2DeviceStatus status, {
    required bool switchEngine,
  }) async {
    final accepted = await showFlickDialog<bool>(
      context: context,
      barrierLabel: 'USB DAC detected',
      builder: (dialogContext) => FlickDialog(
        title: 'USB DAC detected',
        icon: LucideIcons.usb,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${status.device.productName} is connected.',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: AppConstants.spacingSm),
            Text(
              switchEngine
                  ? "Switch to the Bit-perfect (USB DAC) engine? Flick takes exclusive control of the USB path and bypasses Android's audio processing for unaltered sound."
                  : 'Enable Bit-perfect (USB DAC) mode? Flick takes exclusive control of the USB path for unaltered sound.',
              style: TextStyle(color: AppColors.textSecondary, height: 1.45),
            ),
          ],
        ),
        actions: [
          FlickDialogButton(
            label: 'Not now',
            onPressed: () => Navigator.of(dialogContext).pop(false),
          ),
          FlickDialogButton(
            label: 'Enable',
            style: FlickDialogButtonStyle.primary,
            onPressed: () => Navigator.of(dialogContext).pop(true),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;

    if (switchEngine) {
      await ref
          .read(playerServiceProvider)
          .setAudioEnginePreference(AudioEnginePreference.isochronousUsb);
    }
    final applied =
        await ref.read(uac2ServiceProvider).setBitPerfectEnabled(true);
    ref.invalidate(audioEnginePreferenceProvider);
    ref.invalidate(uac2BitPerfectEnabledProvider);
    ref.invalidate(uac2ExclusiveDacModeProvider);
    ref.invalidate(killIsochronousUsbOnQuitProvider);
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            applied
                ? 'Bit-perfect (USB DAC) enabled. Restart the app to apply playback changes.'
                : 'Bit-perfect (USB DAC) could not be enabled. Check the USB diagnostics for the failure reason.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
