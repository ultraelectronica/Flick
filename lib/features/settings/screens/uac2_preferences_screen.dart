import 'dart:async';

import 'package:flick/widgets/common/flick_dialog.dart';
import 'package:flick/widgets/common/flick_option_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/models/audio_output_diagnostics.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/services/uac2_preferences_service.dart';
import 'package:flick/services/uac2_service.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/src/rust/api/audio_api.dart' as rust_audio;
import 'package:flick/src/rust/audio/engine.dart' show AudioApiPreference;
import 'package:flick/widgets/common/display_mode_wrapper.dart';
import 'package:flick/widgets/common/engine_restart_notice.dart';
import 'package:flick/widgets/uac2/uac2_volume_control.dart';
import 'package:flick/features/settings/screens/logs_screen.dart';
import 'package:flick/features/player/widgets/ambient_background.dart';

class Uac2PreferencesScreen extends ConsumerStatefulWidget {
  const Uac2PreferencesScreen({super.key});

  @override
  ConsumerState<Uac2PreferencesScreen> createState() =>
      _Uac2PreferencesScreenState();
}

class _Uac2PreferencesScreenState extends ConsumerState<Uac2PreferencesScreen> {
  bool _pendingEngineRestart = false;

  @override
  Widget build(BuildContext context) {
                    final preferencesService = ref.watch(uac2PreferencesServiceProvider);
                    final formatPrefAsync = ref.watch(uac2FormatPreferenceProvider);
                    final preferredFormatAsync = ref.watch(uac2PreferredFormatProvider);
                    final audioFormatAsync = ref.watch(audioFormatEnabledProvider);
                    final bitPerfectAsync = ref.watch(uac2BitPerfectEnabledProvider);
                    final dapBitPerfectAsync = ref.watch(uac2DapBitPerfectEnabledProvider);
                    final tuning432HzAsync = ref.watch(uac2432HzTuningEnabledProvider);
                    final audioEngineAsync = ref.watch(audioEnginePreferenceProvider);
                    final androidAudioApiAsync = ref.watch(androidAudioApiProvider);
                    final developerModeAsync = ref.watch(developerModeEnabledProvider);
                    final diagnostics = ref.watch(audioOutputDiagnosticsProvider);
                    final killIsochronousUsbOnQuitAsync = ref.watch(killIsochronousUsbOnQuitProvider);
                    final dsdOutputModeAsync = ref.watch(dsdOutputModeProvider);
                    final currentSong = ref.watch(currentSongProvider);

    return DisplayModeWrapper(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            Container(
              decoration: const BoxDecoration(
                gradient: AppColors.backgroundGradient,
              ),
            ),
            Positioned.fill(
              child: AmbientBackground(song: currentSong),
            ),
            SafeArea(
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
                          if (_pendingEngineRestart) ...[
                            const EngineRestartNotice(),
                            const SizedBox(height: AppConstants.spacingLg),
                          ],
                          _buildSectionHeader(context, 'Audio Format'),
                          _buildFormatPreferences(
                            context,
                            preferencesService,
                            formatPrefAsync,
                            preferredFormatAsync,
                            audioFormatAsync,
                          ),
                          const SizedBox(height: AppConstants.spacingLg),
                          _buildSectionHeader(context, 'Experimental'),
                          _buildExperimentalWarning(context),
                          _buildDsdOptions(
                            context,
                            preferencesService,
                            dsdOutputModeAsync,
                          ),
                          const SizedBox(height: AppConstants.spacingSm),
                          _build432HzTuningTile(
                            context,
                            preferencesService,
                            tuning432HzAsync,
                          ),
                          const SizedBox(height: AppConstants.spacingLg),
                          _buildSectionHeader(context, 'Advanced'),
                          _buildAdvancedOptions(
                            context,
                            preferencesService,
                            audioEngineAsync,
                            androidAudioApiAsync,
                            developerModeAsync,
                            bitPerfectAsync,
                            dapBitPerfectAsync,
                            killIsochronousUsbOnQuitAsync,
                            diagnostics,
                          ),
                          if (audioEngineAsync.when(
                            data: (e) => e == AudioEnginePreference.isochronousUsb,
                            loading: () => false,
                            error: (_, _) => false,
                          )) ...[
                            const SizedBox(height: AppConstants.spacingLg),
                            _buildSectionHeader(context, 'Volume'),
                            const Uac2VolumeControl(),
                          ],
                          const SizedBox(height: AppConstants.navBarHeight + 120),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
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
          Text(
            'UAC2 Preferences',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: context.adaptiveTextPrimary,
            ),
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

  Widget _buildFormatPreferences(
    BuildContext context,
    Uac2PreferencesService service,
    AsyncValue<Uac2FormatPreference> formatPrefAsync,
    AsyncValue<Uac2AudioFormat?> preferredFormatAsync,
    AsyncValue<bool> audioFormatAsync,
  ) {
    final bitPerfectAsync = ref.watch(uac2BitPerfectEnabledProvider);
    final isBitPerfectEnabled = bitPerfectAsync.value ?? false;
    final isAudioFormatEnabled = audioFormatAsync.value ?? true;
    final formatBlocked = !isAudioFormatEnabled || isBitPerfectEnabled;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Column(
        children: [
          // Audio Format master toggle
          audioFormatAsync.when(
            data: (enabled) => _buildSwitchTile(
              context,
              icon: LucideIcons.settings,
              title: 'Audio Format',
              subtitle: enabled
                  ? 'Format strategy and custom format controls are active.'
                  : 'Format controls are disabled. The engine uses its default format.',
              value: enabled,
              onChanged: (value) async {
                await service.setAudioFormatEnabled(value);
                ref.invalidate(audioFormatEnabledProvider);
              },
            ),
            loading: () => _buildLoadingTile(context),
            error: (_, _) => _buildErrorTile(context),
          ),
          _buildDivider(),
          formatPrefAsync.when(
            data: (formatPref) => _buildNavigationTile(
              context,
              icon: LucideIcons.slidersHorizontal,
              title: 'Format Strategy',
              subtitle: formatBlocked
                  ? 'Disabled in Bit-perfect (USB DAC) mode (exact rate required)'
                  : !isAudioFormatEnabled
                  ? 'Audio Format is disabled'
                  : _getFormatPreferenceLabel(formatPref),
              onTap: formatBlocked
                  ? () => isBitPerfectEnabled
                      ? _showBitPerfectBlockedDialog(
                          context,
                          'Format Strategy',
                          'Format strategy is disabled in Bit-perfect (USB DAC) mode because exact sample rate matching is required. Disable Bit-perfect (USB DAC) to change format preferences.',
                        )
                      : _showBitPerfectBlockedDialog(
                          context,
                          'Format Strategy',
                          'Format strategy is unavailable because Audio Format is disabled in Settings.',
                        )
                  : () => _showFormatPreferenceDialog(
                      context,
                      service,
                      formatPref,
                    ),
              isDisabled: formatBlocked,
            ),
            loading: () => _buildLoadingTile(context),
            error: (_, _) => _buildErrorTile(context),
          ),
          _buildDivider(),
          preferredFormatAsync.when(
            data: (format) => _buildNavigationTile(
              context,
              icon: LucideIcons.music,
              title: 'Custom Format',
              subtitle: formatBlocked
                  ? isBitPerfectEnabled
                      ? 'Disabled in Bit-perfect (USB DAC) mode (exact rate required)'
                      : 'Audio Format is disabled'
                  : format != null
                  ? format.isDsdStream
                        ? '${format.displayRateLabel} / ${format.channels}ch'
                        : '${format.sampleRate ~/ 1000}kHz / ${format.bitDepth}bit / ${format.channels}ch'
                  : 'Not set',
              onTap: formatBlocked
                  ? () => isBitPerfectEnabled
                      ? _showBitPerfectBlockedDialog(
                          context,
                          'Custom Format',
                          'Custom format is disabled in Bit-perfect (USB DAC) mode because exact sample rate matching is required. Disable Bit-perfect (USB DAC) to set custom formats.',
                        )
                      : _showBitPerfectBlockedDialog(
                          context,
                          'Custom Format',
                          'Custom format is unavailable because Audio Format is disabled in Settings.',
                        )
                  : () => _showCustomFormatDialog(context, service, format),
              isDisabled: formatBlocked,
            ),
            loading: () => _buildLoadingTile(context),
            error: (_, _) => _buildErrorTile(context),
          ),
        ],
      ),
    );
  }

  Widget _buildAdvancedOptions(
    BuildContext context,
    Uac2PreferencesService service,
    AsyncValue<AudioEnginePreference> audioEngineAsync,
    AsyncValue<AudioApiPreference> androidAudioApiAsync,
    AsyncValue<bool> developerModeAsync,
    AsyncValue<bool> bitPerfectAsync,
    AsyncValue<bool> dapBitPerfectAsync,
    AsyncValue<bool> killIsochronousUsbOnQuitAsync,
    AudioOutputDiagnostics? diagnostics,
  ) {
    final isBitPerfectBlocked = audioEngineAsync.when(
      data: (e) => e != AudioEnginePreference.isochronousUsb,
      loading: () => false,
      error: (_, _) => false,
    );
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Column(
        children: [
          audioEngineAsync.when(
            data: (engine) => _buildNavigationTile(
              context,
              icon: LucideIcons.audioLines,
              title: 'Playback Engine',
              subtitle: _audioEnginePreferenceSubtitle(engine),
               onTap: () => _showAudioEngineDialog(
                 context,
                 service,
                 engine,
                 diagnostics: diagnostics,
               ),
            ),
            loading: () => _buildLoadingTile(context),
            error: (_, _) => _buildErrorTile(context),
          ),
          if (audioEngineAsync.when(
            data: (e) => e == AudioEnginePreference.rustOboe,
            loading: () => false,
            error: (_, _) => false,
          )) ...[
            _buildDivider(),
            androidAudioApiAsync.when(
              data: (pref) => _buildNavigationTile(
                context,
                icon: LucideIcons.circuitBoard,
                title: 'Android Audio API',
                subtitle: _androidAudioApiSubtitle(pref),
                onTap: () => _showAndroidAudioApiDialog(context, service, pref),
              ),
              loading: () => _buildLoadingTile(context),
              error: (_, _) => _buildErrorTile(context),
            ),
          ],
          _buildDivider(),
          developerModeAsync.when(
            data: (enabled) => _buildSwitchTile(
              context,
              icon: LucideIcons.badgeInfo,
              title: 'Developer Mode',
              subtitle:
                  'Show verbose audio diagnostics and engine/session trace logs.',
              value: enabled,
              onChanged: (value) async {
                await service.setDeveloperModeEnabled(value);
                ref.invalidate(developerModeEnabledProvider);
              },
            ),
            loading: () => _buildLoadingTile(context),
            error: (_, _) => _buildErrorTile(context),
          ),
          ...developerModeAsync.maybeWhen(
            data: (enabled) => enabled
                ? [
                    _buildDivider(),
                    _buildNavigationTile(
                      context,
                      icon: LucideIcons.terminal,
                      title: 'Logs',
                      subtitle: 'Verbose Dart, Rust, and crash logs',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const LogsScreen(),
                        ),
                      ),
                    ),
                  ]
                : [],
            orElse: () => [],
          ),
          _buildDivider(),
          _buildModeStatusTile(context, diagnostics),
          _buildDivider(),
          bitPerfectAsync.when(
            data: (enabled) => _buildSwitchTile(
              context,
              icon: LucideIcons.lock,
              title: 'Bit-perfect (USB DAC)',
              subtitle:
                  'Use the verified direct USB path and disable software DSP controls that would break bit-perfect playback on an external USB DAC.',
              value: enabled,
              enabled: !isBitPerfectBlocked,
              disabledSubtitle: 'Requires the Isochronous USB playback engine.',
              onChanged: (value) async {
                final changed = value != enabled;
                final applied = await ref
                    .read(uac2ServiceProvider)
                    .setBitPerfectEnabled(value);
                ref.invalidate(uac2BitPerfectEnabledProvider);
ref.invalidate(uac2ExclusiveDacModeProvider);
              ref.invalidate(killIsochronousUsbOnQuitProvider);
                if (!context.mounted) {
                  return;
                }
                if (!applied && value) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Bit-perfect (USB DAC) could not be enabled. Check the USB diagnostics for the failure reason.',
                      ),
                    ),
                  );
                  return;
                }
                if (changed) {
                  _showRestartRequiredToast(context);
                }
              },
            ),
            loading: () => _buildLoadingTile(context),
            error: (_, _) => _buildErrorTile(context),
          ),
          if (diagnostics?.detectedDap == true) ...[
            _buildDivider(),
            dapBitPerfectAsync.when(
              data: (enabled) => _buildSwitchTile(
                context,
                icon: LucideIcons.headphones,
                title: 'Bit-perfect (DAP Internal)',
                subtitle:
                    'Bypass all DSP (EQ, dynamics, crossfade, speed) on the native DAP internal high-res path. Disable to use software effects. Turning off Bit-perfect (USB DAC) also disables this.',
                value: enabled,
                onChanged: (value) async {
                  await PlayerService().setDapBitPerfectEnabled(value);
                  ref.invalidate(uac2DapBitPerfectEnabledProvider);
                  if (!context.mounted) return;
                  final messenger = ScaffoldMessenger.of(context);
                  messenger.removeCurrentSnackBar();
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(
                        value
                            ? 'Bit-perfect (DAP Internal) enabled — all DSP bypassed.'
                            : 'Bit-perfect (DAP Internal) disabled — software effects active.',
                      ),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                  _showRestartRequiredToast(context);
                },
              ),
              loading: () => _buildLoadingTile(context),
              error: (_, _) => _buildErrorTile(context),
            ),
          ],
          _buildDivider(),
          killIsochronousUsbOnQuitAsync.when(
            data: (killOnQuit) => _buildSwitchTile(
              context,
              icon: LucideIcons.power,
              title: 'Stop USB on Quit',
              subtitle: killOnQuit
                  ? 'The Isochronous USB engine will be stopped when the app quits.'
                  : 'The Isochronous USB engine will stay alive when the app quits.',
              value: killOnQuit,
              onChanged: (value) async {
                await service.setKillIsochronousUsbOnQuit(value);
                ref.invalidate(killIsochronousUsbOnQuitProvider);
                unawaited(Uac2Service.instance.syncKillIsochronousUsbOnQuitToNative());
              },
            ),
            loading: () => _buildLoadingTile(context),
            error: (_, _) => _buildErrorTile(context),
          ),
          _buildDivider(),
          _buildNavigationTile(
            context,
            icon: LucideIcons.trash2,
            title: 'Reset Preferences',
            subtitle: 'Clear all UAC2 settings',
            onTap: () => _showResetConfirmation(context, service),
            isDestructive: true,
          ),
        ],
      ),
    );
  }

  Widget _buildSwitchTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool enabled = true,
    String? disabledSubtitle,
  }) {
    final effectiveSubtitle =
        !enabled && disabledSubtitle != null ? disabledSubtitle : subtitle;
    final tile = Padding(
      padding: const EdgeInsets.all(AppConstants.spacingMd),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.glassBackground,
              borderRadius: BorderRadius.circular(AppConstants.radiusSm),
            ),
            child: Icon(icon, color: context.adaptiveTextSecondary, size: 20),
          ),
          const SizedBox(width: AppConstants.spacingMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: context.adaptiveTextPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  effectiveSubtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.adaptiveTextTertiary,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: enabled ? value : false,
            onChanged: enabled ? onChanged : null,
            activeThumbColor: AppColors.accent,
          ),
        ],
      ),
    );
    if (!enabled) {
      return Opacity(opacity: 0.55, child: tile);
    }
    return tile;
  }

  String _audioEnginePreferenceSubtitle(AudioEnginePreference engine) {
    return switch (engine) {
      AudioEnginePreference.exoPlayer => 'just_audio / ExoPlayer (default)',
      AudioEnginePreference.rustOboe => 'Rust via Oboe',
      AudioEnginePreference.isochronousUsb => 'Isochronous USB',
    };
  }

  String _androidAudioApiSubtitle(AudioApiPreference pref) {
    return switch (pref) {
      AudioApiPreference.auto => 'AAudio with OpenSL ES fallback (default)',
      AudioApiPreference.aAudio => 'AAudio (Android 8.1+)',
      AudioApiPreference.openSles => 'OpenSL ES (legacy)',
    };
  }

  Future<void> _showAndroidAudioApiDialog(
    BuildContext context,
    Uac2PreferencesService service,
    AudioApiPreference current,
  ) async {
    await showFlickDialog<void>(
      context: context,
      barrierLabel: 'Android Audio API',
      builder: (dialogContext) {
        return FlickDialog(
          title: 'Android Audio API',
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildAudioEngineOption(
                dialogContext,
                title: 'Auto',
                subtitle:
                    'Let Oboe pick the best API. AAudio first, then OpenSL ES fallback.',
                selected: current == AudioApiPreference.auto,
                onTap: () async {
                  final changed = current != AudioApiPreference.auto;
                  await service.setAndroidAudioApi(AudioApiPreference.auto);
                  rust_audio.audioSetAudioApi(preference: AudioApiPreference.auto);
                  ref.invalidate(androidAudioApiProvider);
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop();
                  }
                  if (changed && context.mounted) {
                    _showRestartRequiredToast(context);
                  }
                },
              ),
              const SizedBox(height: AppConstants.spacingSm),
              _buildAudioEngineOption(
                dialogContext,
                title: 'AAudio',
                subtitle:
                    'Use AAudio directly. Lowest latency on Android 8.1 and newer.',
                selected: current == AudioApiPreference.aAudio,
                onTap: () async {
                  final changed = current != AudioApiPreference.aAudio;
                  await service.setAndroidAudioApi(AudioApiPreference.aAudio);
                  rust_audio.audioSetAudioApi(preference: AudioApiPreference.aAudio);
                  ref.invalidate(androidAudioApiProvider);
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop();
                  }
                  if (changed && context.mounted) {
                    _showRestartRequiredToast(context);
                  }
                },
              ),
              const SizedBox(height: AppConstants.spacingSm),
              _buildAudioEngineOption(
                dialogContext,
                title: 'OpenSL ES',
                subtitle:
                    'Use the legacy OpenSL ES backend. Troubleshooting fallback for older or problematic devices.',
                selected: current == AudioApiPreference.openSles,
                onTap: () async {
                  final changed = current != AudioApiPreference.openSles;
                  await service.setAndroidAudioApi(AudioApiPreference.openSles);
                  rust_audio.audioSetAudioApi(preference: AudioApiPreference.openSles);
                  ref.invalidate(androidAudioApiProvider);
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop();
                  }
                  if (changed && context.mounted) {
                    _showRestartRequiredToast(context);
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showAudioEngineDialog(
    BuildContext context,
    Uac2PreferencesService service,
    AudioEnginePreference current, {
    AudioOutputDiagnostics? diagnostics,
  }) async {
    final dapBothOff = diagnostics?.detectedDap == true &&
        !(await service.getBitPerfectEnabled()) &&
        !(await service.getDapBitPerfectEnabled());
    final effective =
        (dapBothOff && current == AudioEnginePreference.exoPlayer)
            ? AudioEnginePreference.rustOboe
            : current;
    if (dapBothOff && current == AudioEnginePreference.exoPlayer) {
      await PlayerService().setAudioEnginePreference(AudioEnginePreference.rustOboe);
      ref.invalidate(audioEnginePreferenceProvider);
    }

    await showFlickDialog<void>(
      context: context,
      barrierLabel: 'Playback Engine',
      builder: (dialogContext) {
        return FlickDialog(
          title: 'Playback Engine',
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (dapBothOff) ...[
                _buildEngineLockCallout(dialogContext),
                const SizedBox(height: AppConstants.spacingMd),
              ],
              _buildAudioEngineOption(
                dialogContext,
                title: 'just_audio / ExoPlayer',
                subtitle: dapBothOff
                    ? 'Disabled while both bit-perfect options are off on this DAP.'
                    : 'Default Android playback engine used by Flick right now.',
                selected: effective == AudioEnginePreference.exoPlayer,
                enabled: !dapBothOff,
                badgeText: dapBothOff ? 'Locked' : null,
                onTap: dapBothOff
                    ? null
                    : () async {
                        final wasBitPerfectEnabled =
                            await service.getBitPerfectEnabled();
                        await PlayerService().setAudioEnginePreference(
                          AudioEnginePreference.exoPlayer,
                        );
                        if (wasBitPerfectEnabled) {
                          await ref
                              .read(uac2ServiceProvider)
                              .setBitPerfectEnabled(false);
                          ref.invalidate(uac2BitPerfectEnabledProvider);
                          ref.invalidate(uac2ExclusiveDacModeProvider);
                          ref.invalidate(killIsochronousUsbOnQuitProvider);
                        }
                        ref.invalidate(audioEnginePreferenceProvider);
                        if (dialogContext.mounted) {
                          Navigator.of(dialogContext).pop();
                        }
                        if (current != AudioEnginePreference.exoPlayer &&
                            context.mounted) {
                          setState(() => _pendingEngineRestart = true);
                        }
                      },
              ),
              const SizedBox(height: AppConstants.spacingSm),
              _buildAudioEngineOption(
                dialogContext,
                title: 'Rust via Oboe',
                subtitle: dapBothOff
                    ? 'Keeps software volume and DSP active on the DAP shared path.'
                    : 'Android-managed Rust playback path using the native Oboe backend.',
                selected: effective == AudioEnginePreference.rustOboe,
                badgeText:
                    (dapBothOff && effective != current) ? 'Active' : null,
                onTap: () async {
                  final wasBitPerfectEnabled =
                      await service.getBitPerfectEnabled();
                  await PlayerService().setAudioEnginePreference(
                    AudioEnginePreference.rustOboe,
                  );
                  if (wasBitPerfectEnabled) {
                    await ref
                        .read(uac2ServiceProvider)
                        .setBitPerfectEnabled(false);
                    ref.invalidate(uac2BitPerfectEnabledProvider);
                    ref.invalidate(uac2ExclusiveDacModeProvider);
                    ref.invalidate(killIsochronousUsbOnQuitProvider);
                  }
                  ref.invalidate(audioEnginePreferenceProvider);
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop();
                  }
                  if (current != AudioEnginePreference.rustOboe &&
                      context.mounted) {
                    setState(() => _pendingEngineRestart = true);
                  }
                },
              ),
              const SizedBox(height: AppConstants.spacingSm),
              _buildAudioEngineOption(
                dialogContext,
                title: 'Isochronous USB',
                subtitle:
                    'Direct libusb isochronous USB engine. Best paired with Bit-perfect (USB DAC) for verified external DAC playback.',
                selected: effective == AudioEnginePreference.isochronousUsb,
                onTap: () async {
                  await PlayerService().setAudioEnginePreference(
                    AudioEnginePreference.isochronousUsb,
                  );
                  ref.invalidate(audioEnginePreferenceProvider);
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop();
                  }
                  if (current != AudioEnginePreference.isochronousUsb &&
                      context.mounted) {
                    setState(() => _pendingEngineRestart = true);
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEngineLockCallout(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppConstants.spacingMd),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppConstants.radiusMd),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            LucideIcons.lock,
            color: AppColors.accent,
            size: 18,
          ),
          const SizedBox(width: AppConstants.spacingSm),
          Expanded(
            child: Text(
              'Both bit-perfect options are off on this DAP, so the standard engine is unavailable. You can still use Rust via Oboe or Isochronous USB.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: context.adaptiveTextSecondary,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAudioEngineOption(
    BuildContext context, {
    required String title,
    required String subtitle,
    required bool selected,
    bool enabled = true,
    String? badgeText,
    String? disabledText,
    VoidCallback? onTap,
  }) {
    final chipText = badgeText ?? (!enabled ? disabledText : null);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(AppConstants.radiusMd),
        child: Opacity(
          opacity: enabled ? 1 : 0.55,
          child: Container(
            padding: const EdgeInsets.all(AppConstants.spacingMd),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppConstants.radiusMd),
              border: Border.all(
                color: selected
                    ? AppColors.accent.withValues(alpha: 0.45)
                    : AppColors.glassBorder,
              ),
              color: AppColors.surfaceLight.withValues(alpha: 0.35),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: selected
                      ? AppColors.accent
                      : context.adaptiveTextTertiary,
                  size: 20,
                ),
                const SizedBox(width: AppConstants.spacingMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: context.adaptiveTextPrimary,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                          if (chipText != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.accent.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(
                                  AppConstants.radiusSm,
                                ),
                              ),
                              child: Text(
                                chipText,
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: AppColors.accent,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: context.adaptiveTextSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showRestartRequiredToast(BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Restart the app to apply playback changes.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showDeviceRestartRequiredToast(BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Restart your device to apply output format changes.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Widget _buildFormatWarningCallout(BuildContext context, String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppConstants.spacingMd),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppConstants.radiusMd),
        border: Border.all(color: Colors.amber.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            color: Colors.amber.shade300,
            size: 18,
          ),
          const SizedBox(width: AppConstants.spacingSm),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: context.adaptiveTextSecondary,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeStatusTile(
    BuildContext context,
    AudioOutputDiagnostics? diagnostics,
  ) {
    final modeLabel = _currentPlaybackModeLabel(diagnostics);
    final modeDescription = switch (diagnostics?.pathManagement) {
      AudioPathManagement.directUsbExperimental =>
        'Exclusive USB is active and bypassing the Android mixer.',
      AudioPathManagement.alsaDirectDap =>
        'Direct ALSA output is active and bypassing the Android audio server.',
      AudioPathManagement.managedDirectExclusive =>
        'Exclusive direct PCM is active and bypassing the Android mixer at the track\'s native rate.',
      AudioPathManagement.androidManagedLowLatency =>
        'Playback is using Android-managed output and may be resampled.',
      AudioPathManagement.androidManagedShared =>
        'Playback is using the standard Android output path.',
      null =>
        'Playback mode will update after the next route or playback refresh.',
    };

    return Padding(
      padding: const EdgeInsets.all(AppConstants.spacingMd),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.glassBackground,
              borderRadius: BorderRadius.circular(AppConstants.radiusSm),
            ),
            child: Icon(
              LucideIcons.badgeInfo,
              color: context.adaptiveTextSecondary,
              size: 20,
            ),
          ),
          const SizedBox(width: AppConstants.spacingMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Current Playback Mode',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: context.adaptiveTextPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  modeLabel,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.adaptiveTextSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  modeDescription,
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

  String _currentPlaybackModeLabel(AudioOutputDiagnostics? diagnostics) {
    return diagnostics?.capabilityStateLabel ?? 'Waiting for playback';
  }

  Widget _buildNavigationTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool isDestructive = false,
    bool isDisabled = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: isDisabled ? null : onTap,
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        child: Opacity(
          opacity: isDisabled ? 0.5 : 1.0,
          child: Padding(
            padding: const EdgeInsets.all(AppConstants.spacingMd),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: isDestructive
                        ? Colors.red.withValues(alpha: 0.1)
                        : AppColors.glassBackground,
                    borderRadius: BorderRadius.circular(AppConstants.radiusSm),
                  ),
                  child: Icon(
                    icon,
                    color: isDestructive
                        ? Colors.red.shade400
                        : context.adaptiveTextSecondary,
                    size: 20,
                  ),
                ),
                const SizedBox(width: AppConstants.spacingMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: isDestructive
                              ? Colors.red.shade400
                              : context.adaptiveTextPrimary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: context.adaptiveTextTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!isDisabled)
                  Icon(
                    LucideIcons.chevronRight,
                    color: context.adaptiveTextTertiary,
                    size: 20,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingTile(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(AppConstants.spacingMd),
      child: Center(child: CircularProgressIndicator()),
    );
  }

  Widget _buildErrorTile(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppConstants.spacingMd),
      child: Text(
        'Error loading preference',
        style: TextStyle(color: Colors.red.shade400),
      ),
    );
  }

  Widget _buildDivider() {
    return const Divider(height: 1, thickness: 1, color: AppColors.glassBorder);
  }

  String _getFormatPreferenceLabel(Uac2FormatPreference pref) {
    switch (pref) {
      case Uac2FormatPreference.highestQuality:
        return 'Highest Quality';
      case Uac2FormatPreference.compatibility:
        return 'Compatibility';
      case Uac2FormatPreference.custom:
        return 'Custom';
    }
  }

  void _showFormatPreferenceDialog(
    BuildContext context,
    Uac2PreferencesService service,
    Uac2FormatPreference current,
  ) {
    showFlickDialog<void>(
      context: context,
      barrierLabel: 'Format Strategy',
      builder: (context) => FlickDialog(
        title: 'Format Strategy',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildFormatWarningCallout(
              context,
              'Changing sample rate, bit depth, or channel handling can resample songs and may affect playback quality, pitch, speed, or stability on some devices.',
            ),
            const SizedBox(height: AppConstants.spacingMd),
            _buildFormatOption(
              context,
              Uac2FormatPreference.highestQuality,
              'Highest Quality',
              'Use the highest fixed output rate and bit depth available',
              current,
              service,
            ),
            const SizedBox(height: AppConstants.spacingSm),
            _buildFormatOption(
              context,
              Uac2FormatPreference.compatibility,
              'Compatibility',
              'Use a fixed 48kHz/16bit output for better compatibility',
              current,
              service,
            ),
            const SizedBox(height: AppConstants.spacingSm),
            _buildFormatOption(
              context,
              Uac2FormatPreference.custom,
              'Custom',
              'Use your selected fixed sample rate, bit depth, and channels',
              current,
              service,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFormatOption(
    BuildContext context,
    Uac2FormatPreference preference,
    String title,
    String description,
    Uac2FormatPreference current,
    Uac2PreferencesService service,
  ) {
    final isSelected = preference == current;
    return FlickOptionTile(
      title: title,
      description: description,
      selected: isSelected,
      onTap: () async {
        final changed = preference != current;
        await service.setFormatPreference(preference);
        ref.invalidate(uac2FormatPreferenceProvider);
        if (context.mounted) Navigator.of(context).pop();
        if (changed && mounted) {
          _showDeviceRestartRequiredToast(this.context);
        }
      },
    );
  }

  void _showCustomFormatDialog(
    BuildContext context,
    Uac2PreferencesService service,
    Uac2AudioFormat? current,
  ) {
    int sampleRate = current?.sampleRate ?? 48000;
    int bitDepth = current?.bitDepth ?? 16;
    int channels = current?.channels ?? 2;

    showFlickDialog<void>(
      context: context,
      barrierLabel: 'Custom Format',
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => FlickDialog(
          title: 'Custom Format',
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildFormatWarningCallout(
                context,
                'Custom format forces playback to the selected output format. If the chosen sample rate, bit depth, or channels do not suit the song or device, you may hear altered sound, pitch, speed, or instability.',
              ),
              const SizedBox(height: AppConstants.spacingMd),
              Text(
                'Sample Rate',
                style: TextStyle(
                  color: context.adaptiveTextSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: AppConstants.spacingSm),
              Wrap(
                spacing: 8,
                children:
                    [
                      44100,
                      48000,
                      88200,
                      96000,
                      176400,
                      192000,
                      352800,
                      384000,
                    ].map((rate) {
                      return ChoiceChip(
                        label: Text('${rate ~/ 1000}kHz'),
                        selected: sampleRate == rate,
                        onSelected: (selected) {
                          if (selected) setState(() => sampleRate = rate);
                        },
                      );
                    }).toList(),
              ),
              const SizedBox(height: AppConstants.spacingMd),
              Text(
                'Bit Depth',
                style: TextStyle(
                  color: context.adaptiveTextSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: AppConstants.spacingSm),
              Wrap(
                spacing: 8,
                children: [16, 24, 32].map((depth) {
                  return ChoiceChip(
                    label: Text('${depth}bit'),
                    selected: bitDepth == depth,
                    onSelected: (selected) {
                      if (selected) setState(() => bitDepth = depth);
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: AppConstants.spacingMd),
              Text(
                'Channels',
                style: TextStyle(
                  color: context.adaptiveTextSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: AppConstants.spacingSm),
              Wrap(
                spacing: 8,
                children: [1, 2].map((ch) {
                  return ChoiceChip(
                    label: Text(ch == 1 ? 'Mono' : 'Stereo'),
                    selected: channels == ch,
                    onSelected: (selected) {
                      if (selected) setState(() => channels = ch);
                    },
                  );
                }).toList(),
              ),
            ],
          ),
          actions: [
            FlickDialogButton(
              label: 'Cancel',
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
            FlickDialogButton(
              label: 'Save',
              style: FlickDialogButtonStyle.primary,
              onPressed: () async {
                final formatChanged =
                    current?.sampleRate != sampleRate ||
                    current?.bitDepth != bitDepth ||
                    current?.channels != channels;
                final previousPreference = await service.getFormatPreference();
                final format = Uac2AudioFormat(
                  sampleRate: sampleRate,
                  bitDepth: bitDepth,
                  channels: channels,
                );
                await service.savePreferredFormat(format);
                await service.setFormatPreference(Uac2FormatPreference.custom);
                ref.invalidate(uac2PreferredFormatProvider);
                ref.invalidate(uac2FormatPreferenceProvider);
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
                if ((formatChanged ||
                        previousPreference != Uac2FormatPreference.custom) &&
                    mounted) {
                  _showDeviceRestartRequiredToast(this.context);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showResetConfirmation(
    BuildContext context,
    Uac2PreferencesService service,
  ) {
    unawaited(
      FlickDialogs.confirm(
        context,
        title: 'Reset Preferences',
        message:
            'Are you sure you want to reset all UAC2 preferences? This action cannot be undone.',
        confirmLabel: 'Reset',
        destructive: true,
      ).then((confirmed) async {
        if (!confirmed) return;
        await service.clearAllPreferences();
        await ref
            .read(uac2ServiceProvider)
            .setBitPerfectEnabled(false, persist: false);
        ref.invalidate(uac2FormatPreferenceProvider);
        ref.invalidate(uac2PreferredFormatProvider);
        ref.invalidate(uac2BitPerfectEnabledProvider);
        ref.invalidate(uac2ExclusiveDacModeProvider);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('UAC2 preferences reset successfully'),
            ),
          );
        }
      }),
    );
  }

  void _showBitPerfectBlockedDialog(
    BuildContext context,
    String featureName,
    String message,
  ) {
    showFlickDialog<void>(
      context: context,
      barrierLabel: '$featureName Unavailable',
      builder: (dialogContext) => FlickDialog(
        title: '$featureName Unavailable',
        icon: Icons.warning_amber_rounded,
        iconColor: Colors.amber.shade300,
        content: Text(
          message,
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          FlickDialogButton(
            label: 'OK',
            style: FlickDialogButtonStyle.primary,
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildDsdOptions(
    BuildContext context,
    Uac2PreferencesService service,
    AsyncValue<DsdOutputMode> outputModeAsync,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Column(
        children: [
          outputModeAsync.when(
            data: (mode) => _buildNavigationTile(
              context,
              icon: LucideIcons.radio,
              title: 'DSD Output Mode',
              subtitle: _dsdOutputModeSubtitle(mode),
              onTap: () => _showDsdOutputModeDialog(context, service, mode),
            ),
            loading: () => _buildLoadingTile(context),
            error: (_, _) => _buildErrorTile(context),
          ),
          _buildDivider(),
          ValueListenableBuilder<DsdWireVariant>(
            valueListenable: Uac2PreferencesService.dsdWireVariantNotifier,
            builder: (context, variant, _) => _buildNavigationTile(
              context,
              icon: LucideIcons.binary,
              title: 'DAP Native Bit Order',
              subtitle: _dsdWireVariantSubtitle(variant),
              onTap: () => _showDsdWireVariantDialog(context, service, variant),
            ),
          ),
          _buildDivider(),
          ValueListenableBuilder<DsdWireGrouping>(
            valueListenable: Uac2PreferencesService.dsdWireGroupingNotifier,
            builder: (context, grouping, _) => _buildNavigationTile(
              context,
              icon: LucideIcons.columns2,
              title: 'DAP Native Byte Grouping',
              subtitle: _dsdWireGroupingSubtitle(grouping),
              onTap: () => _showDsdWireGroupingDialog(context, service, grouping),
            ),
          ),
        ],
      ),
    );
  }

  Widget _build432HzTuningTile(
    BuildContext context,
    Uac2PreferencesService service,
    AsyncValue<bool> tuningAsync,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: tuningAsync.when(
        data: (enabled) => _buildSwitchTile(
          context,
          icon: LucideIcons.music2,
          title: '432 Hz Tuning',
          subtitle:
              'Experimental — down-tune playback by 432/440. This disables bit-perfect passthrough and runs the DSP path.',
          value: enabled,
          onChanged: (value) async {
            if (value && !enabled && !_awaiting432HzConfirm) {
              final confirmed = await _confirmEnable432HzTuning(context);
              if (!confirmed || !context.mounted) return;
            }
            await service.set432HzTuningEnabled(value);
            rust_audio.audioSet432HzTuningEnabled(enabled: value);
            ref.invalidate(uac2432HzTuningEnabledProvider);
          },
        ),
        loading: () => _buildLoadingTile(context),
        error: (_, _) => _buildErrorTile(context),
      ),
    );
  }

  bool _awaiting432HzConfirm = false;

  Future<bool> _confirmEnable432HzTuning(BuildContext context) {
    if (_awaiting432HzConfirm) return Future.value(false);
    _awaiting432HzConfirm = true;
    return FlickDialogs.confirm(
      context,
      title: 'Enable 432 Hz Tuning?',
      message:
          'This slows playback to 432/440 (~1.8% lower pitch and tempo) and '
          'disables bit-perfect passthrough. Music will sound slightly lower '
          'in tone. Only enable this if you intentionally want A=432 tuning.',
      confirmLabel: 'Enable',
      icon: Icons.warning_amber_rounded,
      iconColor: Colors.amber,
    ).then((result) {
      _awaiting432HzConfirm = false;
      return result;
    });
  }

  Widget _buildExperimentalWarning(BuildContext context) {
    const warnColor = Colors.amber;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppConstants.spacingSm),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppConstants.spacingMd,
          vertical: AppConstants.spacingSm,
        ),
        decoration: BoxDecoration(
          color: warnColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppConstants.radiusMd),
          border: Border.all(
            color: warnColor.withValues(alpha: 0.35),
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, size: 16, color: warnColor),
            const SizedBox(width: AppConstants.spacingSm),
            Expanded(
              child: Text(
                'Not recommended for normal usage. DSD playback is unstable and may cause audio glitches.',
                style: TextStyle(
                  color: warnColor.withValues(alpha: 0.9),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _dsdOutputModeSubtitle(DsdOutputMode mode) {
    switch (mode) {
      case DsdOutputMode.auto:
        return 'Auto — Native DSD on DAPs, DoP for USB DACs, PCM otherwise';
      case DsdOutputMode.forcePcm:
        return 'Force PCM — Always convert DSD to PCM';
      case DsdOutputMode.forceDop:
        return 'Force DoP — Always use DSD over PCM (USB DAC)';
      case DsdOutputMode.native:
        return 'Native DSD — Experimental (may be buggy)';
    }
  }


  void _showDsdOutputModeDialog(
    BuildContext context,
    Uac2PreferencesService service,
    DsdOutputMode current,
  ) {
    showFlickDialog<void>(
      context: context,
      barrierLabel: 'DSD Output Mode',
      builder: (dialogContext) => FlickDialog(
        title: 'DSD Output Mode',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildDsdOptionTile(
              dialogContext,
              title: 'Auto',
              subtitle: 'Coming Soon',
              enabled: false,
              selected: false,
              onTap: () {},
            ),
            const SizedBox(height: AppConstants.spacingSm),
            _buildDsdOptionTile(
              dialogContext,
              title: 'Force PCM',
              subtitle: 'Coming Soon',
              enabled: false,
              selected: false,
              onTap: () {},
            ),
            const SizedBox(height: AppConstants.spacingSm),
            _buildDsdOptionTile(
              dialogContext,
              title: 'Force DoP',
              subtitle: 'Coming Soon',
              enabled: false,
              selected: false,
              onTap: () {},
            ),
            const SizedBox(height: AppConstants.spacingSm),
            _buildDsdOptionTile(
              dialogContext,
              title: 'Native DSD (Experimental)',
              subtitle:
                  'Raw DSD stream to DAC. Requires ENCODING_DSD hardware support; '
                  'otherwise falls back to DoP or PCM automatically.',
              selected: current == DsdOutputMode.native,
              onTap: () async {
                await service.setDsdOutputMode(DsdOutputMode.native);
                ref.invalidate(dsdOutputModeProvider);
                if (dialogContext.mounted) Navigator.of(dialogContext).pop();
              },
            ),
          ],
        ),
        actions: [
          FlickDialogButton(
            label: 'Cancel',
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
        ],
      ),
    );
  }

  String _dsdWireVariantSubtitle(DsdWireVariant variant) {
    switch (variant) {
      case DsdWireVariant.auto:
        return 'Auto — BE-MSB default; only change if native DSD hisses';
      case DsdWireVariant.beMsb:
        return 'BE-MSB — big-endian subslot, MSB first (default)';
      case DsdWireVariant.leMsb:
        return 'LE-MSB — little-endian subslot, MSB first';
      case DsdWireVariant.beLsb:
        return 'BE-LSB — big-endian subslot, LSB first';
      case DsdWireVariant.leLsb:
        return 'LE-LSB — little-endian subslot, LSB first';
    }
  }

  String _dsdWireGroupingSubtitle(DsdWireGrouping grouping) {
    switch (grouping) {
      case DsdWireGrouping.auto:
        return 'Auto — U8 byte-interleaved (recommended)';
      case DsdWireGrouping.u32:
        return 'U32 — 4-byte subslots, LLLL|RRRR (legacy)';
      case DsdWireGrouping.u16:
        return 'U16 — 2-byte subslots, LL|RR';
      case DsdWireGrouping.u8:
        return 'U8 — byte-interleaved LRLR';
    }
  }

  void _showDsdWireGroupingDialog(
    BuildContext context,
    Uac2PreferencesService service,
    DsdWireGrouping current,
  ) {
    showFlickDialog<void>(
      context: context,
      barrierLabel: 'DAP Native Byte Grouping',
      builder: (dialogContext) => FlickDialog(
        title: 'DAP Native Byte Grouping',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (grouping, title, subtitle) in [
              (
                DsdWireGrouping.auto,
                'Auto',
                'U8 — byte-interleaved, recommended default'
              ),
              (
                DsdWireGrouping.u32,
                'U32',
                '32-bit subslots: LLLL|RRRR per frame (legacy)'
              ),
              (
                DsdWireGrouping.u16,
                'U16',
                '16-bit subslots: LL|RR per frame'
              ),
              (
                DsdWireGrouping.u8,
                'U8',
                'Byte-interleaved: LRLR stream'
              ),
            ]) ...[
              _buildDsdOptionTile(
                dialogContext,
                title: title,
                subtitle: subtitle,
                selected: current == grouping,
                onTap: () async {
                  await service.setDsdWireGrouping(grouping);
                  // Applies to the very next wire write — live A/B while a
                  // DAP native-DSD track is playing.
                  rust_audio.audioSetSasWireGrouping(
                    grouping: switch (grouping) {
                      DsdWireGrouping.auto => 2,
                      DsdWireGrouping.u32 => 0,
                      DsdWireGrouping.u16 => 1,
                      DsdWireGrouping.u8 => 2,
                    },
                  );
                  if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                },
              ),
              const SizedBox(height: AppConstants.spacingSm),
            ],
          ],
        ),
        actions: [
          FlickDialogButton(
            label: 'Cancel',
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
        ],
      ),
    );
  }

  void _showDsdWireVariantDialog(
    BuildContext context,
    Uac2PreferencesService service,
    DsdWireVariant current,
  ) {
    showFlickDialog<void>(
      context: context,
      barrierLabel: 'DAP Native Bit Order',
      builder: (dialogContext) => FlickDialog(
        title: 'DAP Native Bit Order',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (variant, title, subtitle) in [
              (
                DsdWireVariant.auto,
                'Auto',
                'BE-MSB packing — the default wire convention'
              ),
              (
                DsdWireVariant.beMsb,
                'BE-MSB',
                'Big-endian 32-bit subslot, MSB-first bits'
              ),
              (
                DsdWireVariant.leMsb,
                'LE-MSB',
                'Little-endian subslot, MSB-first bits'
              ),
              (
                DsdWireVariant.beLsb,
                'BE-LSB',
                'Big-endian subslot, LSB-first (bit-reversed) bits'
              ),
              (
                DsdWireVariant.leLsb,
                'LE-LSB',
                'Little-endian subslot, LSB-first bits'
              ),
            ]) ...[
              _buildDsdOptionTile(
                dialogContext,
                title: title,
                subtitle: subtitle,
                selected: current == variant,
                onTap: () async {
                  await service.setDsdWireVariant(variant);
                  // Applies to the very next wire write — live A/B while a
                  // DAP native-DSD track is playing.
                  rust_audio.audioSetSasWireVariant(
                    variant: switch (variant) {
                      DsdWireVariant.auto => 0,
                      DsdWireVariant.beMsb => 0,
                      DsdWireVariant.leMsb => 1,
                      DsdWireVariant.beLsb => 2,
                      DsdWireVariant.leLsb => 3,
                    },
                  );
                  if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                },
              ),
              const SizedBox(height: AppConstants.spacingSm),
            ],
          ],
        ),
        actions: [
          FlickDialogButton(
            label: 'Cancel',
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildDsdOptionTile(
    BuildContext context, {
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(AppConstants.radiusMd),
      child: Container(
        padding: const EdgeInsets.all(AppConstants.spacingMd),
        decoration: BoxDecoration(
          color: enabled
              ? (selected
                  ? AppColors.accent.withValues(alpha: 0.15)
                  : Colors.transparent)
              : AppColors.surface.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(AppConstants.radiusMd),
          border: Border.all(
            color: enabled
                ? (selected
                    ? AppColors.accent.withValues(alpha: 0.4)
                    : AppColors.glassBorder)
                : AppColors.glassBorder.withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: enabled
                          ? (selected ? AppColors.accent : context.adaptiveTextPrimary)
                          : context.adaptiveTextSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: enabled
                          ? context.adaptiveTextSecondary
                          : context.adaptiveTextSecondary.withValues(alpha: 0.5),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check_circle, color: AppColors.accent, size: 20),
          ],
        ),
      ),
    );
  }
}
