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
  final CompressorSettings compressor;
  final LimiterSettings limiter;

  const EqPreset({
    required this.id,
    required this.name,
    required this.enabled,
    required this.mode,
    required this.graphicGainsDb,
    required this.parametricBands,
    this.compressor = const CompressorSettings(),
    this.limiter = const LimiterSettings(),
  });

  EqPreset copyWith({
    String? id,
    String? name,
    bool? enabled,
    EqMode? mode,
    List<double>? graphicGainsDb,
    List<ParametricBand>? parametricBands,
    CompressorSettings? compressor,
    LimiterSettings? limiter,
  }) {
    return EqPreset(
      id: id ?? this.id,
      name: name ?? this.name,
      enabled: enabled ?? this.enabled,
      mode: mode ?? this.mode,
      graphicGainsDb: graphicGainsDb ?? this.graphicGainsDb,
      parametricBands: parametricBands ?? this.parametricBands,
      compressor: compressor ?? this.compressor,
      limiter: limiter ?? this.limiter,
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
            'type': b.type.name,
          },
        )
        .toList(),
    'compressor': {
      'enabled': compressor.enabled,
      'thresholdDb': compressor.thresholdDb,
      'ratio': compressor.ratio,
      'attackMs': compressor.attackMs,
      'releaseMs': compressor.releaseMs,
      'makeupGainDb': compressor.makeupGainDb,
    },
    'limiter': {
      'enabled': limiter.enabled,
      'inputGainDb': limiter.inputGainDb,
      'ceilingDb': limiter.ceilingDb,
      'releaseMs': limiter.releaseMs,
    },
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
          final typeName =
              (m['type'] as String?) ?? ParametricBandType.peaking.name;
          final type = ParametricBandType.values.firstWhere(
            (t) => t.name == typeName,
            orElse: () => ParametricBandType.peaking,
          );
          return ParametricBand(
            enabled: (m['enabled'] as bool?) ?? true,
            frequencyHz: (m['frequencyHz'] as num?)?.toDouble() ?? 1000.0,
            gainDb: (m['gainDb'] as num?)?.toDouble() ?? 0.0,
            q: (m['q'] as num?)?.toDouble() ?? 1.0,
            type: type,
          );
        })
        .toList(growable: false);

    final compressorJson = (json['compressor'] as Map?)
        ?.cast<String, dynamic>();
    final limiterJson = (json['limiter'] as Map?)?.cast<String, dynamic>();

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
      compressor: CompressorSettings(
        enabled: (compressorJson?['enabled'] as bool?) ?? false,
        thresholdDb:
            (compressorJson?['thresholdDb'] as num?)?.toDouble() ?? -18.0,
        ratio: (compressorJson?['ratio'] as num?)?.toDouble() ?? 3.0,
        attackMs: (compressorJson?['attackMs'] as num?)?.toDouble() ?? 12.0,
        releaseMs: (compressorJson?['releaseMs'] as num?)?.toDouble() ?? 140.0,
        makeupGainDb:
            (compressorJson?['makeupGainDb'] as num?)?.toDouble() ?? 0.0,
      ),
      limiter: LimiterSettings(
        enabled: (limiterJson?['enabled'] as bool?) ?? false,
        inputGainDb: (limiterJson?['inputGainDb'] as num?)?.toDouble() ?? 0.0,
        ceilingDb: (limiterJson?['ceilingDb'] as num?)?.toDouble() ?? -0.8,
        releaseMs: (limiterJson?['releaseMs'] as num?)?.toDouble() ?? 80.0,
      ),
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

  static EqPreset _graphicPreset({
    required String id,
    required String name,
    required List<double> graphicGainsDb,
    required List<ParametricBand> parametricBands,
    CompressorSettings compressor = const CompressorSettings(),
    LimiterSettings limiter = const LimiterSettings(),
  }) {
    return EqPreset(
      id: id,
      name: name,
      enabled: true,
      mode: EqMode.graphic,
      graphicGainsDb: List<double>.unmodifiable(graphicGainsDb),
      parametricBands: List<ParametricBand>.unmodifiable(parametricBands),
      compressor: compressor,
      limiter: limiter,
    );
  }

  static final List<EqPreset> presets = [
    _graphicPreset(
      id: 'builtin_flat',
      name: 'Flat',
      graphicGainsDb: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      parametricBands: [
        ParametricBand(frequencyHz: 80, gainDb: 0, q: 1),
        ParametricBand(frequencyHz: 250, gainDb: 0, q: 1),
        ParametricBand(frequencyHz: 1000, gainDb: 0, q: 1),
        ParametricBand(frequencyHz: 4000, gainDb: 0, q: 1),
        ParametricBand(frequencyHz: 12000, gainDb: 0, q: 1),
      ],
    ),
    _graphicPreset(
      id: 'builtin_minimal_audio_morph',
      name: 'Minimal Audio Morph EQ',
      graphicGainsDb: [-0.5, -0.2, 0.3, 0.8, 1.1, 0.7, 0.2, 0.9, 1.2, 0.8],
      parametricBands: [
        ParametricBand(frequencyHz: 90, gainDb: 1.0, q: 0.85),
        ParametricBand(frequencyHz: 280, gainDb: 0.6, q: 1.0),
        ParametricBand(frequencyHz: 1200, gainDb: 0.2, q: 1.1),
        ParametricBand(frequencyHz: 4200, gainDb: 0.9, q: 0.95),
        ParametricBand(frequencyHz: 11000, gainDb: 1.1, q: 0.8),
      ],
    ),
    _graphicPreset(
      id: 'builtin_bass_boost',
      name: 'Bass Boost',
      graphicGainsDb: [6, 5, 4, 2, 0, -1, -2, -2, -2, -2],
      parametricBands: [
        ParametricBand(frequencyHz: 80, gainDb: 6, q: 0.8),
        ParametricBand(frequencyHz: 250, gainDb: 3, q: 0.9),
        ParametricBand(frequencyHz: 1000, gainDb: 0, q: 1.0),
        ParametricBand(frequencyHz: 4000, gainDb: -1, q: 1.1),
        ParametricBand(frequencyHz: 12000, gainDb: -2, q: 1.0),
      ],
    ),
    _graphicPreset(
      id: 'builtin_vocal',
      name: 'Vocal',
      graphicGainsDb: [-2, -2, -1, 1, 3, 4, 3, 1, -1, -2],
      parametricBands: [
        ParametricBand(frequencyHz: 250, gainDb: -1, q: 1.0),
        ParametricBand(frequencyHz: 1000, gainDb: 3, q: 1.2),
        ParametricBand(frequencyHz: 2500, gainDb: 4, q: 1.1),
        ParametricBand(frequencyHz: 4000, gainDb: 2, q: 1.1),
        ParametricBand(frequencyHz: 12000, gainDb: -1, q: 1.0),
      ],
    ),
    _graphicPreset(
      id: 'builtin_treble_boost',
      name: 'Treble Boost',
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
