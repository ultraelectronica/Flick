import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'dart:math' as math;

import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/providers/equalizer_provider.dart';
import 'package:flick/services/eq_preset_service.dart';
import 'package:flick/widgets/common/glass_bottom_sheet.dart';

import 'package:flick/widgets/equalizer/parametric_eq_graph.dart';
import 'package:flick/widgets/equalizer/graphic_eq_graph.dart';

class EqualizerScreen extends ConsumerWidget {
  const EqualizerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(eqEnabledProvider);
    final mode = ref.watch(eqModeProvider);
    final activePresetName = ref.watch(eqActivePresetNameProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(
              title: 'Equalizer',
              subtitle: activePresetName != null
                  ? 'Preset: $activePresetName'
                  : null,
              onBack: () => Navigator.of(context).pop(),
              onPresets: () => _showPresetsBottomSheet(context),
            ),
            const SizedBox(height: AppConstants.spacingMd),
            Expanded(
              child: RepaintBoundary(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppConstants.spacingMd,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _GlassCard(
                        child: Column(
                          children: [
                            _TopControlsRow(enabled: enabled),
                            _Divider(),
                            _ModeAndActionsRow(mode: mode),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppConstants.spacingLg),
                      AnimatedSwitcher(
                        duration: AppConstants.animationNormal,
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        child: mode == EqMode.graphic
                            ? const _GraphicEqView(key: ValueKey('graphic'))
                            : const _ParametricEqView(key: ValueKey('param')),
                      ),
                      const SizedBox(height: AppConstants.navBarHeight + 120),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showPresetsBottomSheet(BuildContext context) {
    GlassBottomSheet.show<void>(
      context: context,
      title: 'Presets',
      maxHeightRatio: 0.6,
      content: _PresetsSheet(),
    );
  }
}

class _PresetsSheet extends ConsumerStatefulWidget {
  const _PresetsSheet();

  @override
  ConsumerState<_PresetsSheet> createState() => _PresetsSheetState();
}

class _PresetsSheetState extends ConsumerState<_PresetsSheet> {
  final EqPresetService _service = EqPresetService();
  bool _loading = true;
  List<EqPreset> _custom = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final presets = await _service.loadCustomPresets();
    if (!mounted) return;
    setState(() {
      _custom = presets;
      _loading = false;
    });
  }

  Future<String?> _askForName(BuildContext context, {String? initial}) async {
    final controller = TextEditingController(text: initial ?? '');
    final result = await showDialog<String?>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.glassBackgroundStrong,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppConstants.radiusLg),
            side: BorderSide(color: AppColors.glassBorder),
          ),
          title: Text(
            initial == null ? 'Save Preset' : 'Rename Preset',
            style: TextStyle(color: context.adaptiveTextPrimary),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: TextStyle(color: context.adaptiveTextPrimary),
            decoration: InputDecoration(
              hintText: 'Preset name',
              hintStyle: TextStyle(color: context.adaptiveTextTertiary),
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: AppColors.glassBorder),
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: context.adaptiveTextPrimary),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: Text(
                'Cancel',
                style: TextStyle(color: context.adaptiveTextSecondary),
              ),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              child: Text(
                'Save',
                style: TextStyle(color: context.adaptiveTextPrimary),
              ),
            ),
          ],
        );
      },
    );
    controller.dispose();
    final trimmed = result?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  EqPreset _currentAsPreset({required String id, required String name}) {
    final s = ref.read(equalizerProvider);
    return EqPreset(
      id: id,
      name: name,
      enabled: s.enabled,
      mode: s.mode,
      graphicGainsDb: List<double>.of(s.graphicGainsDb, growable: false),
      parametricBands: List<ParametricBand>.of(
        s.parametricBands,
        growable: false,
      ),
    );
  }

  Future<void> _apply(EqPreset preset) async {
    ref
        .read(equalizerProvider.notifier)
        .applyPreset(
          presetName: preset.name,
          enabled: preset.enabled,
          mode: preset.mode,
          graphicGainsDb: preset.graphicGainsDb,
          parametricBands: preset.parametricBands,
        );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _saveNewPreset() async {
    final name = await _askForName(context);
    if (name == null) return;
    final id = 'custom_${DateTime.now().millisecondsSinceEpoch}';
    final preset = _currentAsPreset(id: id, name: name);
    await _service.upsertCustomPreset(preset);
    await _load();
  }

  Future<void> _renamePreset(EqPreset preset) async {
    final name = await _askForName(context, initial: preset.name);
    if (name == null) return;
    await _service.upsertCustomPreset(preset.copyWith(name: name));
    await _load();
  }

  Future<void> _deletePreset(EqPreset preset) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.glassBackgroundStrong,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusLg),
          side: BorderSide(color: AppColors.glassBorder),
        ),
        title: Text(
          'Delete preset?',
          style: TextStyle(color: context.adaptiveTextPrimary),
        ),
        content: Text(
          'Delete "${preset.name}"? This cannot be undone.',
          style: TextStyle(color: context.adaptiveTextSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              'Cancel',
              style: TextStyle(color: context.adaptiveTextSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _service.deleteCustomPreset(preset.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.only(top: AppConstants.spacingMd),
        child: Center(
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: AppColors.textPrimary,
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: AppConstants.spacingMd),
        _GlassCard(
          child: Column(
            children: [
              _PresetActionRow(
                icon: LucideIcons.plus,
                title: 'Save current as preset',
                subtitle: 'Create a custom preset',
                onTap: _saveNewPreset,
              ),
            ],
          ),
        ),
        const SizedBox(height: AppConstants.spacingLg),
        _SectionHeader(title: 'Built-in'),
        _GlassCard(
          child: Column(
            children: [
              for (final p in BuiltInEqPresets.presets) ...[
                _PresetRow(
                  title: p.name,
                  subtitle: p.mode == EqMode.graphic ? 'Graphic' : 'Parametric',
                  onTap: () => _apply(p),
                ),
                if (p != BuiltInEqPresets.presets.last) _Divider(),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppConstants.spacingLg),
        _SectionHeader(title: 'Custom'),
        _GlassCard(
          child: _custom.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(AppConstants.spacingMd),
                  child: Text(
                    'No custom presets yet.',
                    style: TextStyle(
                      fontFamily: 'ProductSans',
                      color: AppColors.textSecondary,
                    ),
                  ),
                )
              : Column(
                  children: [
                    for (final p in _custom) ...[
                      _CustomPresetRow(
                        preset: p,
                        onApply: () => _apply(p),
                        onRename: () => _renamePreset(p),
                        onDelete: () => _deletePreset(p),
                      ),
                      if (p != _custom.last) _Divider(),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: AppConstants.spacingMd),
      ],
    );
  }
}

class _PresetActionRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _PresetActionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppConstants.spacingMd),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.glassBackgroundStrong,
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
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: context.adaptiveTextPrimary,
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
}

class _PresetRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _PresetRow({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppConstants.spacingMd),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.glassBackgroundStrong,
                  borderRadius: BorderRadius.circular(AppConstants.radiusSm),
                ),
                child: Icon(
                  LucideIcons.bookmark,
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
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: context.adaptiveTextPrimary,
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
                LucideIcons.check,
                color: context.adaptiveTextTertiary,
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CustomPresetRow extends StatelessWidget {
  final EqPreset preset;
  final VoidCallback onApply;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const _CustomPresetRow({
    required this.preset,
    required this.onApply,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.all(AppConstants.spacingMd),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.glassBackgroundStrong,
                borderRadius: BorderRadius.circular(AppConstants.radiusSm),
              ),
              child: Icon(
                LucideIcons.star,
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
                    preset.name,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: context.adaptiveTextPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    preset.mode == EqMode.graphic ? 'Graphic' : 'Parametric',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: context.adaptiveTextTertiary,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Apply',
              onPressed: onApply,
              icon: Icon(
                LucideIcons.check,
                color: context.adaptiveTextPrimary,
                size: 18,
              ),
            ),
            IconButton(
              tooltip: 'Rename',
              onPressed: onRename,
              icon: Icon(
                LucideIcons.pencil,
                color: context.adaptiveTextSecondary,
                size: 18,
              ),
            ),
            IconButton(
              tooltip: 'Delete',
              onPressed: onDelete,
              icon: const Icon(
                LucideIcons.trash2,
                color: Colors.redAccent,
                size: 18,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final String? subtitle;
  final VoidCallback onBack;
  final VoidCallback onPresets;

  const _Header({
    required this.title,
    required this.onBack,
    required this.onPresets,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppConstants.spacingLg,
        vertical: AppConstants.spacingMd,
      ),
      child: Row(
        children: [
          Container(
            decoration: BoxDecoration(
              color: AppColors.glassBackground,
              borderRadius: BorderRadius.circular(AppConstants.radiusMd),
              border: Border.all(color: AppColors.glassBorder),
            ),
            child: IconButton(
              icon: Icon(
                LucideIcons.arrowLeft,
                color: context.adaptiveTextPrimary,
                size: context.responsiveIcon(AppConstants.iconSizeMd),
              ),
              onPressed: onBack,
            ),
          ),
          const SizedBox(width: AppConstants.spacingMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: context.adaptiveTextPrimary,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: context.adaptiveTextTertiary,
                    ),
                  ),
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: AppColors.glassBackground,
              borderRadius: BorderRadius.circular(AppConstants.radiusMd),
              border: Border.all(color: AppColors.glassBorder),
            ),
            child: IconButton(
              tooltip: 'Presets',
              icon: Icon(
                LucideIcons.library,
                color: context.adaptiveTextPrimary,
                size: context.responsiveIcon(AppConstants.iconSizeMd),
              ),
              onPressed: onPresets,
            ),
          ),
        ],
      ),
    );
  }
}

class _TopControlsRow extends ConsumerWidget {
  final bool enabled;
  const _TopControlsRow({required this.enabled});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.all(AppConstants.spacingMd),
        child: Row(
          children: [
            _IconTile(icon: LucideIcons.power, enabled: enabled),
            const SizedBox(width: AppConstants.spacingMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Equalizer',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: context.adaptiveTextPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    enabled ? 'Enabled' : 'Disabled',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: context.adaptiveTextTertiary,
                    ),
                  ),
                ],
              ),
            ),
            _PillSwitch(
              value: enabled,
              onChanged: (v) =>
                  ref.read(equalizerProvider.notifier).setEnabled(v),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeAndActionsRow extends ConsumerWidget {
  final EqMode mode;
  const _ModeAndActionsRow({required this.mode});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.all(AppConstants.spacingMd),
        child: Row(
          children: [
            Expanded(
              child: _ModeToggle(
                mode: mode,
                onChanged: (m) =>
                    ref.read(equalizerProvider.notifier).setMode(m),
              ),
            ),
            const SizedBox(width: AppConstants.spacingMd),
            _ActionButton(
              icon: LucideIcons.rotateCcw,
              label: 'Reset',
              onTap: () {
                final notifier = ref.read(equalizerProvider.notifier);
                if (mode == EqMode.graphic) {
                  notifier.resetGraphic();
                } else {
                  notifier.resetParametric();
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _GraphicEqView extends ConsumerWidget {
  const _GraphicEqView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(eqEnabledProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title: 'Graphic EQ'),
        const SizedBox(height: AppConstants.spacingSm),
        _GlassCard(
          child: Padding(
            padding: const EdgeInsets.all(AppConstants.spacingMd),
            child: RepaintBoundary(
              child: Opacity(
                opacity: enabled ? 1.0 : 0.5,
                child: const SizedBox(height: 220, child: GraphicEqGraph()),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppConstants.spacingMd),
        _GlassCard(
          child: SizedBox(
            height: 320,
            child: RepaintBoundary(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.all(AppConstants.spacingMd),
                itemCount: EqualizerState.defaultGraphicFrequenciesHz.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(width: AppConstants.spacingMd),
                itemBuilder: (context, i) {
                  return _GraphicBandSlider(
                    index: i,
                    frequencyHz: EqualizerState.defaultGraphicFrequenciesHz[i],
                    enabled: enabled,
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GraphicBandSlider extends ConsumerWidget {
  final int index;
  final double frequencyHz;
  final bool enabled;

  const _GraphicBandSlider({
    required this.index,
    required this.frequencyHz,
    required this.enabled,
  });

  String _freqLabel() {
    if (frequencyHz >= 1000) {
      final k = frequencyHz / 1000.0;
      return '${k.toStringAsFixed(k >= 10 ? 0 : 1)}k';
    }
    return frequencyHz.toStringAsFixed(0);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gainDb = ref.watch(eqGraphicGainDbProvider(index));

    return RepaintBoundary(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            '${gainDb.toStringAsFixed(1)} dB',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: enabled
                  ? context.adaptiveTextSecondary
                  : context.adaptiveTextTertiary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppConstants.spacingXs),
          Expanded(
            child: Opacity(
              opacity: enabled ? 1.0 : 0.5,
              child: RotatedBox(
                quarterTurns: -1,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    activeTrackColor: context.adaptiveTextPrimary,
                    inactiveTrackColor: AppColors.glassBorderStrong,
                    thumbColor: context.adaptiveTextPrimary,
                    overlayColor: context.adaptiveTextPrimary.withValues(
                      alpha: 0.08,
                    ),
                  ),
                  child: Slider(
                    value: gainDb,
                    min: EqualizerNotifier.gainMinDb,
                    max: EqualizerNotifier.gainMaxDb,
                    onChanged: enabled
                        ? (v) => ref
                              .read(equalizerProvider.notifier)
                              .setGraphicGainDb(index, v)
                        : null,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppConstants.spacingXs),
          Text(
            _freqLabel(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: enabled
                  ? context.adaptiveTextPrimary
                  : context.adaptiveTextTertiary,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            'Hz',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: context.adaptiveTextTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

class _ParametricEqView extends ConsumerWidget {
  const _ParametricEqView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(eqEnabledProvider);
    final bandCount = ref.watch(
      equalizerProvider.select((s) => s.parametricBands.length),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title: 'Parametric EQ'),
        const SizedBox(height: AppConstants.spacingSm),
        _GlassCard(
          child: Padding(
            padding: const EdgeInsets.all(AppConstants.spacingMd),
            child: RepaintBoundary(
              child: Opacity(
                opacity: enabled ? 1.0 : 0.5,
                child: const SizedBox(height: 220, child: ParametricEqGraph()),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppConstants.spacingLg),
        _GlassCard(
          child: RepaintBoundary(
            child: Padding(
              padding: const EdgeInsets.all(AppConstants.spacingMd),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListView.separated(
                    physics: const NeverScrollableScrollPhysics(),
                    shrinkWrap: true,
                    itemCount: bandCount,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: AppConstants.spacingMd),
                    itemBuilder: (context, i) {
                      return _ParametricBandEditor(index: i, enabled: enabled);
                    },
                  ),
                  const SizedBox(height: AppConstants.spacingSm),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: enabled
                          ? () => ref
                                .read(equalizerProvider.notifier)
                                .addParametricBand()
                          : null,
                      icon: const Icon(LucideIcons.plus, size: 18),
                      label: const Text(
                        'Add band',
                        style: TextStyle(
                          fontFamily: 'ProductSans',
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: context.adaptiveTextPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ParametricBandEditor extends ConsumerWidget {
  final int index;
  final bool enabled;

  const _ParametricBandEditor({required this.index, required this.enabled});

  static const double _minHz = 20.0;
  static const double _maxHz = 20000.0;

  double _hzToT(double hz) {
    final clamped = hz.clamp(_minHz, _maxHz).toDouble();
    final logMin = math.log(_minHz);
    final logMax = math.log(_maxHz);
    return (math.log(clamped) - logMin) / (logMax - logMin);
  }

  double _tToHz(double t) {
    final logMin = math.log(_minHz);
    final logMax = math.log(_maxHz);
    final v = logMin + (logMax - logMin) * t.clamp(0.0, 1.0);
    return math.exp(v);
  }

  String _hzLabel(double hz) {
    if (hz >= 1000) {
      final k = hz / 1000.0;
      return '${k.toStringAsFixed(k >= 10 ? 0 : 1)} kHz';
    }
    return '${hz.toStringAsFixed(0)} Hz';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final band = ref.watch(eqParamBandProvider(index));

    return RepaintBoundary(
      child: Opacity(
        opacity: enabled ? 1.0 : 0.5,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: context.scaleSize(AppConstants.containerSizeSm),
                  height: context.scaleSize(AppConstants.containerSizeSm),
                  decoration: BoxDecoration(
                    color: AppColors.glassBackgroundStrong,
                    borderRadius: BorderRadius.circular(AppConstants.radiusSm),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${index + 1}',
                    style: const TextStyle(
                      fontFamily: 'ProductSans',
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: AppConstants.spacingMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _hzLabel(band.frequencyHz),
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: context.adaptiveTextPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${band.gainDb.toStringAsFixed(1)} dB  •  Q ${band.q.toStringAsFixed(2)}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: context.adaptiveTextTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                _PillSwitch(
                  value: band.enabled,
                  onChanged: enabled
                      ? (v) => ref
                            .read(equalizerProvider.notifier)
                            .setParamBandEnabled(index, v)
                      : (_) {},
                ),
              ],
            ),
            const SizedBox(height: AppConstants.spacingSm),
            // Frequency: slider + direct Hz input
            Row(
              children: [
                Icon(
                  LucideIcons.waves,
                  size: context.responsiveIcon(AppConstants.iconSizeSm),
                  color: (enabled && band.enabled)
                      ? context.adaptiveTextSecondary
                      : context.adaptiveTextTertiary,
                ),
                const SizedBox(width: AppConstants.spacingSm),
                Expanded(
                  child: Text(
                    'Frequency',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: (enabled && band.enabled)
                          ? context.adaptiveTextSecondary
                          : context.adaptiveTextTertiary,
                    ),
                  ),
                ),
                SizedBox(
                  width: 80,
                  child: TextFormField(
                    key: ValueKey('param_freq_${index}_${band.frequencyHz}'),
                    initialValue: band.frequencyHz.toStringAsFixed(0),
                    enabled: enabled && band.enabled,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: false,
                      signed: false,
                    ),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: context.adaptiveTextPrimary,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(
                          AppConstants.radiusSm,
                        ),
                        borderSide: BorderSide(color: AppColors.glassBorder),
                      ),
                      disabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(
                          AppConstants.radiusSm,
                        ),
                        borderSide: BorderSide(color: AppColors.glassBorder),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(
                          AppConstants.radiusSm,
                        ),
                        borderSide: BorderSide(
                          color: context.adaptiveTextPrimary,
                        ),
                      ),
                      suffixText: 'Hz',
                      suffixStyle: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: context.adaptiveTextTertiary),
                    ),
                    onFieldSubmitted: (value) {
                      final parsed = double.tryParse(value.trim());
                      if (parsed == null) return;
                      ref
                          .read(equalizerProvider.notifier)
                          .setParamBandFreqHz(index, parsed);
                    },
                  ),
                ),
              ],
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: context.adaptiveTextPrimary,
                inactiveTrackColor: AppColors.glassBorderStrong,
                thumbColor: context.adaptiveTextPrimary,
                overlayColor: context.adaptiveTextPrimary.withValues(
                  alpha: 0.08,
                ),
              ),
              child: Slider(
                value: _hzToT(band.frequencyHz),
                min: 0.0,
                max: 1.0,
                onChanged: enabled && band.enabled
                    ? (t) => ref
                          .read(equalizerProvider.notifier)
                          .setParamBandFreqHz(index, _tToHz(t))
                    : null,
              ),
            ),
            const SizedBox(height: AppConstants.spacingSm),
            _LabeledSlider(
              icon: LucideIcons.slidersHorizontal,
              label: 'Gain',
              valueLabel: '${band.gainDb.toStringAsFixed(1)} dB',
              value: band.gainDb,
              min: EqualizerNotifier.gainMinDb,
              max: EqualizerNotifier.gainMaxDb,
              onChanged: enabled && band.enabled
                  ? (v) => ref
                        .read(equalizerProvider.notifier)
                        .setParamBandGainDb(index, v)
                  : null,
            ),
            const SizedBox(height: AppConstants.spacingSm),
            _LabeledSlider(
              icon: LucideIcons.target,
              label: 'Q',
              valueLabel: band.q.toStringAsFixed(2),
              value: band.q,
              min: 0.2,
              max: 10.0,
              onChanged: enabled && band.enabled
                  ? (v) => ref
                        .read(equalizerProvider.notifier)
                        .setParamBandQ(index, v)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _LabeledSlider extends StatelessWidget {
  final IconData icon;
  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double>? onChanged;

  const _LabeledSlider({
    required this.icon,
    required this.label,
    required this.valueLabel,
    required this.value,
    this.min = 0.0,
    this.max = 1.0,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              icon,
              size: context.responsiveIcon(AppConstants.iconSizeSm),
              color: enabled
                  ? context.adaptiveTextSecondary
                  : context.adaptiveTextTertiary,
            ),
            const SizedBox(width: AppConstants.spacingSm),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: enabled
                      ? context.adaptiveTextSecondary
                      : context.adaptiveTextTertiary,
                ),
              ),
            ),
            Text(
              valueLabel,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: enabled
                    ? context.adaptiveTextPrimary
                    : context.adaptiveTextTertiary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            activeTrackColor: context.adaptiveTextPrimary,
            inactiveTrackColor: AppColors.glassBorderStrong,
            thumbColor: context.adaptiveTextPrimary,
            overlayColor: context.adaptiveTextPrimary.withValues(alpha: 0.08),
          ),
          child: Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

class _ModeToggle extends StatelessWidget {
  final EqMode mode;
  final ValueChanged<EqMode> onChanged;

  const _ModeToggle({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: AppColors.glassBackgroundStrong,
        borderRadius: BorderRadius.circular(AppConstants.radiusRound),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            duration: AppConstants.animationNormal,
            curve: Curves.easeOutCubic,
            alignment: mode == EqMode.graphic
                ? Alignment.centerLeft
                : Alignment.centerRight,
            child: FractionallySizedBox(
              widthFactor: 0.5,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.glassBackground,
                    borderRadius: BorderRadius.circular(
                      AppConstants.radiusRound,
                    ),
                    border: Border.all(color: AppColors.glassBorderStrong),
                  ),
                ),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: _ModeToggleButton(
                  label: 'Graphic',
                  selected: mode == EqMode.graphic,
                  onTap: () => onChanged(EqMode.graphic),
                ),
              ),
              Expanded(
                child: _ModeToggleButton(
                  label: 'Parametric',
                  selected: mode == EqMode.parametric,
                  onTap: () => onChanged(EqMode.parametric),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ModeToggleButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ModeToggleButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppConstants.radiusRound),
        onTap: onTap,
        child: Center(
          child: AnimatedDefaultTextStyle(
            duration: AppConstants.animationFast,
            style: TextStyle(
              fontFamily: 'ProductSans',
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: selected
                  ? context.adaptiveTextPrimary
                  : context.adaptiveTextTertiary,
            ),
            child: Text(label),
          ),
        ),
      ),
    );
  }
}

class _PillSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _PillSwitch({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: AppConstants.animationFast,
        width: 48,
        height: 28,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: value
              ? AppColors.textPrimary.withValues(alpha: 0.9)
              : AppColors.glassBackgroundStrong,
          border: Border.all(
            color: value ? Colors.transparent : AppColors.glassBorderStrong,
            width: 1,
          ),
        ),
        child: AnimatedAlign(
          duration: AppConstants.animationFast,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: value ? AppColors.background : AppColors.textTertiary,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppConstants.radiusMd),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppConstants.spacingMd,
            vertical: AppConstants.spacingSm,
          ),
          decoration: BoxDecoration(
            color: AppColors.glassBackground,
            borderRadius: BorderRadius.circular(AppConstants.radiusMd),
            border: Border.all(color: AppColors.glassBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: context.responsiveIcon(AppConstants.iconSizeSm),
                color: context.adaptiveTextPrimary,
              ),
              const SizedBox(width: AppConstants.spacingSm),
              Text(
                label,
                style: const TextStyle(
                  fontFamily: 'ProductSans',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IconTile extends StatelessWidget {
  final IconData icon;
  final bool enabled;

  const _IconTile({required this.icon, required this.enabled});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: context.scaleSize(AppConstants.containerSizeSm),
      height: context.scaleSize(AppConstants.containerSizeSm),
      decoration: BoxDecoration(
        color: enabled
            ? AppColors.glassBackgroundStrong
            : AppColors.glassBackground,
        borderRadius: BorderRadius.circular(AppConstants.radiusSm),
      ),
      child: Icon(
        icon,
        color: enabled
            ? context.adaptiveTextSecondary
            : context.adaptiveTextTertiary,
        size: context.responsiveIcon(AppConstants.iconSizeMd),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
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
}

class _GlassCard extends StatelessWidget {
  final Widget child;
  const _GlassCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: AppConstants.glassBlurSigmaLight,
            sigmaY: AppConstants.glassBlurSigmaLight,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.glassBackground,
              borderRadius: BorderRadius.circular(AppConstants.radiusLg),
              border: Border.all(color: AppColors.glassBorder, width: 1),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Container(
        height: 1,
        margin: EdgeInsets.only(left: 56 + AppConstants.spacingMd),
        color: AppColors.glassBorder,
      ),
    );
  }
}
