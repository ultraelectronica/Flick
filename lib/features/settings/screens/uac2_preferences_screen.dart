import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
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
    final autoConnectAsync = ref.watch(uac2AutoConnectProvider);
    final autoSelectAsync = ref.watch(uac2AutoSelectDeviceProvider);
    final formatPrefAsync = ref.watch(uac2FormatPreferenceProvider);
    final preferredFormatAsync = ref.watch(uac2PreferredFormatProvider);

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
                      _buildSectionHeader(context, 'Connection'),
                      _buildConnectionPreferences(
                        context,
                        preferencesService,
                        autoConnectAsync,
                        autoSelectAsync,
                      ),
                      const SizedBox(height: AppConstants.spacingLg),
                      _buildSectionHeader(context, 'Audio Format'),
                      _buildFormatPreferences(
                        context,
                        preferencesService,
                        formatPrefAsync,
                        preferredFormatAsync,
                      ),
                      const SizedBox(height: AppConstants.spacingLg),
                      _buildSectionHeader(context, 'Advanced'),
                      _buildAdvancedOptions(context, preferencesService),
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

  Widget _buildConnectionPreferences(
    BuildContext context,
    Uac2PreferencesService service,
    AsyncValue<bool> autoConnectAsync,
    AsyncValue<bool> autoSelectAsync,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Column(
        children: [
          autoConnectAsync.when(
            data: (autoConnect) => _buildSwitchTile(
              context,
              icon: LucideIcons.power,
              title: 'Auto-Connect',
              subtitle: 'Automatically connect to last used device on startup',
              value: autoConnect,
              onChanged: (value) async {
                await service.setAutoConnect(value);
                ref.invalidate(uac2AutoConnectProvider);
              },
            ),
            loading: () => _buildLoadingTile(context),
            error: (_, __) => _buildErrorTile(context),
          ),
          _buildDivider(),
          autoSelectAsync.when(
            data: (autoSelect) => _buildSwitchTile(
              context,
              icon: LucideIcons.zap,
              title: 'Auto-Select Device',
              subtitle: 'Automatically select first available USB audio device',
              value: autoSelect,
              onChanged: (value) async {
                await service.setAutoSelectDevice(value);
                ref.invalidate(uac2AutoSelectDeviceProvider);
              },
            ),
            loading: () => _buildLoadingTile(context),
            error: (_, __) => _buildErrorTile(context),
          ),
        ],
      ),
    );
  }

  Widget _buildFormatPreferences(
    BuildContext context,
    Uac2PreferencesService service,
    AsyncValue<Uac2FormatPreference> formatPrefAsync,
    AsyncValue<Uac2AudioFormat?> preferredFormatAsync,
  ) {
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
              subtitle: _getFormatPreferenceLabel(formatPref),
              onTap: () => _showFormatPreferenceDialog(context, service, formatPref),
            ),
            loading: () => _buildLoadingTile(context),
            error: (_, __) => _buildErrorTile(context),
          ),
          _buildDivider(),
          preferredFormatAsync.when(
            data: (format) => _buildNavigationTile(
              context,
              icon: LucideIcons.music,
              title: 'Custom Format',
              subtitle: format != null
                  ? '${format.sampleRate ~/ 1000}kHz / ${format.bitDepth}bit / ${format.channels}ch'
                  : 'Not set',
              onTap: () => _showCustomFormatDialog(context, service, format),
            ),
            loading: () => _buildLoadingTile(context),
            error: (_, __) => _buildErrorTile(context),
          ),
        ],
      ),
    );
  }

  Widget _buildAdvancedOptions(
    BuildContext context,
    Uac2PreferencesService service,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: _buildNavigationTile(
        context,
        icon: LucideIcons.trash2,
        title: 'Reset Preferences',
        subtitle: 'Clear all UAC2 settings',
        onTap: () => _showResetConfirmation(context, service),
        isDestructive: true,
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
            child: Icon(
              icon,
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

  Widget _buildNavigationTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool isDestructive = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
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
              Icon(
                LucideIcons.chevronRight,
                color: context.adaptiveTextTertiary,
                size: 20,
              ),
            ],
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
    return const Divider(
      height: 1,
      thickness: 1,
      color: AppColors.glassBorder,
    );
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
            _buildFormatOption(
              context,
              Uac2FormatPreference.highestQuality,
              'Highest Quality',
              'Always use maximum sample rate and bit depth',
              current,
              service,
            ),
            const SizedBox(height: AppConstants.spacingSm),
            _buildFormatOption(
              context,
              Uac2FormatPreference.compatibility,
              'Compatibility',
              'Use 48kHz/16bit for better compatibility',
              current,
              service,
            ),
            const SizedBox(height: AppConstants.spacingSm),
            _buildFormatOption(
              context,
              Uac2FormatPreference.custom,
              'Custom',
              'Use custom format settings',
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
          await service.setFormatPreference(preference);
          ref.invalidate(uac2FormatPreferenceProvider);
          if (context.mounted) Navigator.of(context).pop();
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
                Icon(
                  Icons.check_circle,
                  color: AppColors.accent,
                  size: 20,
                ),
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
                children: [44100, 48000, 96000, 192000].map((rate) {
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
              ref.invalidate(uac2AutoConnectProvider);
              ref.invalidate(uac2AutoSelectDeviceProvider);
              ref.invalidate(uac2FormatPreferenceProvider);
              ref.invalidate(uac2PreferredFormatProvider);
              if (context.mounted) {
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('UAC2 preferences reset successfully'),
                  ),
                );
              }
            },
            child: Text(
              'Reset',
              style: TextStyle(color: Colors.red.shade400),
            ),
          ),
        ],
      ),
    );
  }
}
