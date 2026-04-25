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
import 'package:flick/widgets/common/display_mode_wrapper.dart';

class Uac2PreferencesScreen extends ConsumerStatefulWidget {
  const Uac2PreferencesScreen({super.key});

  @override
  ConsumerState<Uac2PreferencesScreen> createState() =>
      _Uac2PreferencesScreenState();
}

class _Uac2PreferencesScreenState extends ConsumerState<Uac2PreferencesScreen> {
  @override
  Widget build(BuildContext context) {
                    final preferencesService = ref.watch(uac2PreferencesServiceProvider);
                    final formatPrefAsync = ref.watch(uac2FormatPreferenceProvider);
                    final preferredFormatAsync = ref.watch(uac2PreferredFormatProvider);
                    final bitPerfectAsync = ref.watch(uac2BitPerfectEnabledProvider);
                    final audioEngineAsync = ref.watch(audioEnginePreferenceProvider);
                    final developerModeAsync = ref.watch(developerModeEnabledProvider);
                    final diagnostics = ref.watch(audioOutputDiagnosticsProvider);

    return DisplayModeWrapper(
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
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
                      _buildSectionHeader(context, 'Audio Format'),
                      _buildFormatPreferences(
                        context,
                        preferencesService,
                        formatPrefAsync,
                        preferredFormatAsync,
                      ),
                      const SizedBox(height: AppConstants.spacingLg),
                      _buildSectionHeader(context, 'Advanced'),
                      _buildAdvancedOptions(
                        context,
                        preferencesService,
                        audioEngineAsync,
                        developerModeAsync,
                        bitPerfectAsync,
                        diagnostics,
                      ),
                      const SizedBox(height: AppConstants.navBarHeight + 120),
                    ],
                  ),
                ),
              ),
            ],
          ),
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
  ) {
    final bitPerfectAsync = ref.watch(uac2BitPerfectEnabledProvider);
    final isBitPerfectEnabled = bitPerfectAsync.value ?? false;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Column(
        children: [
          formatPrefAsync.when(
            data: (formatPref) => _buildNavigationTile(
              context,
              icon: LucideIcons.settings,
              title: 'Format Strategy',
              subtitle: isBitPerfectEnabled
                  ? 'Disabled in bit-perfect mode (exact rate required)'
                  : _getFormatPreferenceLabel(formatPref),
              onTap: isBitPerfectEnabled
                  ? () => _showBitPerfectBlockedDialog(
                      context,
                      'Format Strategy',
                      'Format strategy is disabled in bit-perfect mode because exact sample rate matching is required. Disable bit-perfect mode to change format preferences.',
                    )
                  : () => _showFormatPreferenceDialog(
                      context,
                      service,
                      formatPref,
                    ),
              isDisabled: isBitPerfectEnabled,
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
              subtitle: isBitPerfectEnabled
                  ? 'Disabled in bit-perfect mode (exact rate required)'
                  : format != null
                  ? '${format.sampleRate ~/ 1000}kHz / ${format.bitDepth}bit / ${format.channels}ch'
                  : 'Not set',
              onTap: isBitPerfectEnabled
                  ? () => _showBitPerfectBlockedDialog(
                      context,
                      'Custom Format',
                      'Custom format is disabled in bit-perfect mode because exact sample rate matching is required. Disable bit-perfect mode to set custom formats.',
                    )
                  : () => _showCustomFormatDialog(context, service, format),
              isDisabled: isBitPerfectEnabled,
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
    AsyncValue<bool> developerModeAsync,
    AsyncValue<bool> bitPerfectAsync,
    AudioOutputDiagnostics? diagnostics,
  ) {
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
              onTap: () => _showAudioEngineDialog(context, service, engine),
            ),
            loading: () => _buildLoadingTile(context),
            error: (_, _) => _buildErrorTile(context),
          ),
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
          _buildDivider(),
          _buildModeStatusTile(context, diagnostics),
          _buildDivider(),
          bitPerfectAsync.when(
            data: (enabled) => _buildSwitchTile(
              context,
              icon: LucideIcons.lock,
              title: 'Bit-perfect USB',
              subtitle:
                  'Use the verified direct USB path and disable software DSP controls that would break bit-perfect playback.',
              value: enabled,
              onChanged: (value) async {
                final changed = value != enabled;
                final applied = await ref
                    .read(uac2ServiceProvider)
                    .setBitPerfectEnabled(value);
                ref.invalidate(uac2BitPerfectEnabledProvider);
                ref.invalidate(uac2ExclusiveDacModeProvider);
                if (!context.mounted) {
                  return;
                }
                if (!applied && value) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Bit-perfect USB could not be enabled. Check the USB diagnostics for the failure reason.',
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
  }) {
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
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.adaptiveTextTertiary,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppColors.accent,
          ),
        ],
      ),
    );
  }

  String _audioEnginePreferenceSubtitle(AudioEnginePreference engine) {
    return switch (engine) {
      AudioEnginePreference.exoPlayer => 'just_audio / ExoPlayer (default)',
      AudioEnginePreference.rustOboe => 'Rust via Oboe',
      AudioEnginePreference.isochronousUsb => 'Isochronous USB',
    };
  }

  Future<void> _showAudioEngineDialog(
    BuildContext context,
    Uac2PreferencesService service,
    AudioEnginePreference current,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppConstants.radiusLg),
          ),
          title: Text(
            'Playback Engine',
            style: TextStyle(color: context.adaptiveTextPrimary),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildAudioEngineOption(
                dialogContext,
                title: 'just_audio / ExoPlayer',
                subtitle:
                    'Default Android playback engine used by Flick right now.',
                selected: current == AudioEnginePreference.exoPlayer,
                onTap: () async {
                  final changed = current != AudioEnginePreference.exoPlayer;
                  await service.setAudioEnginePreference(
                    AudioEnginePreference.exoPlayer,
                  );
                  ref.invalidate(audioEnginePreferenceProvider);
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
                title: 'Rust via Oboe',
                subtitle:
                    'Android-managed Rust playback path using the native Oboe backend.',
                selected: current == AudioEnginePreference.rustOboe,
                onTap: () async {
                  final changed = current != AudioEnginePreference.rustOboe;
                  await service.setAudioEnginePreference(
                    AudioEnginePreference.rustOboe,
                  );
                  ref.invalidate(audioEnginePreferenceProvider);
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
                title: 'Isochronous USB',
                subtitle:
                    'Direct libusb isochronous USB engine. Best paired with Bit-perfect USB for verified external DAC playback.',
                selected: current == AudioEnginePreference.isochronousUsb,
                onTap: () async {
                  final changed =
                      current != AudioEnginePreference.isochronousUsb;
                  await service.setAudioEnginePreference(
                    AudioEnginePreference.isochronousUsb,
                  );
                  ref.invalidate(audioEnginePreferenceProvider);
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

  Widget _buildAudioEngineOption(
    BuildContext context, {
    required String title,
    required String subtitle,
    required bool selected,
    bool enabled = true,
    VoidCallback? onTap,
  }) {
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
                          if (!enabled)
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
                                'Coming soon',
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
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        ),
        title: Text(
          'Format Strategy',
          style: TextStyle(color: context.adaptiveTextPrimary),
        ),
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
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () async {
          final changed = preference != current;
          await service.setFormatPreference(preference);
          ref.invalidate(uac2FormatPreferenceProvider);
          if (context.mounted) Navigator.of(context).pop();
          if (changed && mounted) {
            _showDeviceRestartRequiredToast(this.context);
          }
        },
        borderRadius: BorderRadius.circular(AppConstants.radiusMd),
        child: Container(
          padding: const EdgeInsets.all(AppConstants.spacingMd),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.accent.withValues(alpha: 0.1)
                : AppColors.glassBackground,
            borderRadius: BorderRadius.circular(AppConstants.radiusMd),
            border: Border.all(
              color: isSelected ? AppColors.accent : AppColors.glassBorder,
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
                        color: context.adaptiveTextPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 12,
                        color: context.adaptiveTextTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              if (isSelected)
                Icon(Icons.check_circle, color: AppColors.accent, size: 20),
            ],
          ),
        ),
      ),
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

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          scrollable: true,
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppConstants.radiusLg),
          ),
          title: Text(
            'Custom Format',
            style: TextStyle(color: context.adaptiveTextPrimary),
          ),
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
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                'Cancel',
                style: TextStyle(color: context.adaptiveTextSecondary),
              ),
            ),
            TextButton(
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
                if (context.mounted) Navigator.of(context).pop();
                if ((formatChanged ||
                        previousPreference != Uac2FormatPreference.custom) &&
                    mounted) {
                  _showDeviceRestartRequiredToast(this.context);
                }
              },
              child: const Text(
                'Save',
                style: TextStyle(color: AppColors.accent),
              ),
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
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        ),
        title: Text(
          'Reset Preferences',
          style: TextStyle(color: context.adaptiveTextPrimary),
        ),
        content: Text(
          'Are you sure you want to reset all UAC2 preferences? This action cannot be undone.',
          style: TextStyle(color: context.adaptiveTextSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              'Cancel',
              style: TextStyle(color: context.adaptiveTextSecondary),
            ),
          ),
          TextButton(
            onPressed: () async {
              await service.clearAllPreferences();
              await ref
                  .read(uac2ServiceProvider)
                  .setBitPerfectEnabled(false, persist: false);
              ref.invalidate(uac2FormatPreferenceProvider);
              ref.invalidate(uac2PreferredFormatProvider);
              ref.invalidate(uac2BitPerfectEnabledProvider);
              ref.invalidate(uac2ExclusiveDacModeProvider);
              if (context.mounted) {
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('UAC2 preferences reset successfully'),
                  ),
                );
              }
            },
            child: Text('Reset', style: TextStyle(color: Colors.red.shade400)),
          ),
        ],
      ),
    );
  }

  void _showBitPerfectBlockedDialog(
    BuildContext context,
    String featureName,
    String message,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        ),
        title: Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: Colors.amber.shade300,
              size: 24,
            ),
            const SizedBox(width: AppConstants.spacingSm),
            Expanded(
              child: Text(
                '$featureName Unavailable',
                style: TextStyle(color: context.adaptiveTextPrimary),
              ),
            ),
          ],
        ),
        content: Text(
          message,
          style: TextStyle(color: context.adaptiveTextSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK', style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );
  }
}
