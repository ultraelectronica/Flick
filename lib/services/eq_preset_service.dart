import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:flick/providers/equalizer_provider.dart';

class EqPreset {
  final String id;
  final String name;
  final bool enabled;
  final EqMode mode;
  final List<double> graphicGainsDb;
  final List<ParametricBand> parametricBands;

  const EqPreset({
    required this.id,
    required this.name,
    required this.enabled,
    required this.mode,
    required this.graphicGainsDb,
    required this.parametricBands,
  });

  EqPreset copyWith({
    String? id,
    String? name,
    bool? enabled,
    EqMode? mode,
    List<double>? graphicGainsDb,
    List<ParametricBand>? parametricBands,
  }) {
    return EqPreset(
      id: id ?? this.id,
      name: name ?? this.name,
      enabled: enabled ?? this.enabled,
      mode: mode ?? this.mode,
      graphicGainsDb: graphicGainsDb ?? this.graphicGainsDb,
      parametricBands: parametricBands ?? this.parametricBands,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'enabled': enabled,
    'mode': mode.name,
    'graphicGainsDb': graphicGainsDb,
    'parametricBands': parametricBands
        .map(
          (b) => {
            'enabled': b.enabled,
            'frequencyHz': b.frequencyHz,
            'gainDb': b.gainDb,
            'q': b.q,
          },
        )
        .toList(),
  };

  factory EqPreset.fromJson(Map<String, dynamic> json) {
    final modeName = (json['mode'] as String?) ?? EqMode.graphic.name;
    final mode = EqMode.values.firstWhere(
      (m) => m.name == modeName,
      orElse: () => EqMode.graphic,
    );

    final gains = (json['graphicGainsDb'] as List<dynamic>? ?? const [])
        .map((e) => (e as num).toDouble())
        .toList(growable: false);

    final bandsJson = (json['parametricBands'] as List<dynamic>? ?? const []);
    final bands = bandsJson
        .map((e) {
          final m = e as Map<String, dynamic>;
          return ParametricBand(
            enabled: (m['enabled'] as bool?) ?? true,
            frequencyHz: (m['frequencyHz'] as num?)?.toDouble() ?? 1000.0,
            gainDb: (m['gainDb'] as num?)?.toDouble() ?? 0.0,
            q: (m['q'] as num?)?.toDouble() ?? 1.0,
          );
        })
        .toList(growable: false);

    return EqPreset(
      id: (json['id'] as String?) ?? '',
      name: (json['name'] as String?) ?? 'Preset',
      enabled: (json['enabled'] as bool?) ?? true,
      mode: mode,
      graphicGainsDb: gains.isEmpty
          ? List<double>.filled(10, 0.0, growable: false)
          : gains,
      parametricBands: bands.isEmpty
          ? List<ParametricBand>.generate(
              5,
              (i) => ParametricBand(
                frequencyHz: EqualizerState.defaultParametricFrequenciesHz[i],
              ),
              growable: false,
            )
          : bands,
    );
  }
}

class EqPresetService {
  static const String _customPresetsKey = 'eq_custom_presets_v1';

  Future<List<EqPreset>> loadCustomPresets() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_customPresetsKey) ?? const [];
    final result = <EqPreset>[];
    for (final s in raw) {
      try {
        final map = jsonDecode(s) as Map<String, dynamic>;
        final preset = EqPreset.fromJson(map);
        if (preset.id.isNotEmpty) result.add(preset);
      } catch (_) {
        // Skip invalid entries.
      }
    }
    return result;
  }

  Future<void> saveCustomPresets(List<EqPreset> presets) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = presets.map((p) => jsonEncode(p.toJson())).toList();
    await prefs.setStringList(_customPresetsKey, raw);
  }

  Future<void> upsertCustomPreset(EqPreset preset) async {
    final existing = await loadCustomPresets();
    final idx = existing.indexWhere((p) => p.id == preset.id);
    final next = List<EqPreset>.of(existing);
    if (idx >= 0) {
      next[idx] = preset;
    } else {
      next.add(preset);
    }
    await saveCustomPresets(next);
  }

  Future<void> deleteCustomPreset(String id) async {
    final existing = await loadCustomPresets();
    existing.removeWhere((p) => p.id == id);
    await saveCustomPresets(existing);
  }
}

class BuiltInEqPresets {
  BuiltInEqPresets._();

  static const List<EqPreset> presets = [
    EqPreset(
      id: 'builtin_flat',
      name: 'Flat',
      enabled: true,
      mode: EqMode.graphic,
      graphicGainsDb: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      parametricBands: [
        ParametricBand(frequencyHz: 80, gainDb: 0, q: 1),
        ParametricBand(frequencyHz: 250, gainDb: 0, q: 1),
        ParametricBand(frequencyHz: 1000, gainDb: 0, q: 1),
        ParametricBand(frequencyHz: 4000, gainDb: 0, q: 1),
        ParametricBand(frequencyHz: 12000, gainDb: 0, q: 1),
      ],
    ),
    EqPreset(
      id: 'builtin_bass_boost',
      name: 'Bass Boost',
      enabled: true,
      mode: EqMode.graphic,
      graphicGainsDb: [6, 5, 4, 2, 0, -1, -2, -2, -2, -2],
      parametricBands: [
        ParametricBand(frequencyHz: 80, gainDb: 6, q: 0.8),
        ParametricBand(frequencyHz: 250, gainDb: 3, q: 0.9),
        ParametricBand(frequencyHz: 1000, gainDb: 0, q: 1.0),
        ParametricBand(frequencyHz: 4000, gainDb: -1, q: 1.1),
        ParametricBand(frequencyHz: 12000, gainDb: -2, q: 1.0),
      ],
    ),
    EqPreset(
      id: 'builtin_vocal',
      name: 'Vocal',
      enabled: true,
      mode: EqMode.graphic,
      graphicGainsDb: [-2, -2, -1, 1, 3, 4, 3, 1, -1, -2],
      parametricBands: [
        ParametricBand(frequencyHz: 250, gainDb: -1, q: 1.0),
        ParametricBand(frequencyHz: 1000, gainDb: 3, q: 1.2),
        ParametricBand(frequencyHz: 2500, gainDb: 4, q: 1.1),
        ParametricBand(frequencyHz: 4000, gainDb: 2, q: 1.1),
        ParametricBand(frequencyHz: 12000, gainDb: -1, q: 1.0),
      ],
    ),
    EqPreset(
      id: 'builtin_treble_boost',
      name: 'Treble Boost',
      enabled: true,
      mode: EqMode.graphic,
      graphicGainsDb: [-2, -2, -2, -1, 0, 1, 3, 4, 5, 6],
      parametricBands: [
        ParametricBand(frequencyHz: 80, gainDb: -2, q: 1.0),
        ParametricBand(frequencyHz: 1000, gainDb: 1, q: 1.0),
        ParametricBand(frequencyHz: 4000, gainDb: 3, q: 1.1),
        ParametricBand(frequencyHz: 8000, gainDb: 5, q: 1.0),
        ParametricBand(frequencyHz: 12000, gainDb: 6, q: 0.9),
      ],
    ),
  ];
}
