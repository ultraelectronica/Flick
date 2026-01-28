import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum EqMode { graphic, parametric }

@immutable
class ParametricBand {
  final bool enabled;
  final double frequencyHz; // 20..20000
  final double gainDb; // -12..+12 (UI only)
  final double q; // 0.2..10

  const ParametricBand({
    this.enabled = true,
    required this.frequencyHz,
    this.gainDb = 0.0,
    this.q = 1.0,
  });

  ParametricBand copyWith({
    bool? enabled,
    double? frequencyHz,
    double? gainDb,
    double? q,
  }) {
    return ParametricBand(
      enabled: enabled ?? this.enabled,
      frequencyHz: frequencyHz ?? this.frequencyHz,
      gainDb: gainDb ?? this.gainDb,
      q: q ?? this.q,
    );
  }
}

@immutable
class EqualizerState {
  final bool enabled;
  final EqMode mode;

  /// Graphic EQ band gains in dB (UI only).
  final List<double> graphicGainsDb; // length = 10

  /// Parametric bands (UI only).
  /// Starts with 5 bands but can grow up to a configurable maximum.
  final List<ParametricBand> parametricBands;

  /// Active preset name (optional display).
  final String? activePresetName;

  const EqualizerState({
    this.enabled = true,
    this.mode = EqMode.graphic,
    required this.graphicGainsDb,
    required this.parametricBands,
    this.activePresetName,
  });

  EqualizerState copyWith({
    bool? enabled,
    EqMode? mode,
    List<double>? graphicGainsDb,
    List<ParametricBand>? parametricBands,
    String? activePresetName,
    bool clearActivePresetName = false,
  }) {
    return EqualizerState(
      enabled: enabled ?? this.enabled,
      mode: mode ?? this.mode,
      graphicGainsDb: graphicGainsDb ?? this.graphicGainsDb,
      parametricBands: parametricBands ?? this.parametricBands,
      activePresetName: clearActivePresetName
          ? null
          : (activePresetName ?? this.activePresetName),
    );
  }

  static const List<double> defaultGraphicFrequenciesHz = <double>[
    32,
    64,
    125,
    250,
    500,
    1000,
    2000,
    4000,
    8000,
    16000,
  ];

  static const List<double> defaultParametricFrequenciesHz = <double>[
    80,
    250,
    1000,
    4000,
    12000,
  ];

  static EqualizerState initial() {
    return EqualizerState(
      enabled: true,
      mode: EqMode.graphic,
      graphicGainsDb: List<double>.filled(10, 0.0, growable: false),
      parametricBands: List<ParametricBand>.generate(
        5,
        (i) => ParametricBand(frequencyHz: defaultParametricFrequenciesHz[i]),
        growable: false,
      ),
      activePresetName: null,
    );
  }
}

/// Notifies graph painter to repaint without broad rebuilds.
class EqGraphRepaintController extends ChangeNotifier {
  void bump() => notifyListeners();
}

final eqGraphRepaintControllerProvider = Provider<EqGraphRepaintController>((
  ref,
) {
  final controller = EqGraphRepaintController();
  ref.onDispose(controller.dispose);
  return controller;
});

class EqualizerNotifier extends Notifier<EqualizerState> {
  static const double gainMinDb = -12.0;
  static const double gainMaxDb = 12.0;
  static const int maxParametricBands = 8;

  @override
  EqualizerState build() => EqualizerState.initial();

  void setEnabled(bool value) {
    state = state.copyWith(enabled: value);
    ref.read(eqGraphRepaintControllerProvider).bump();
  }

  void setMode(EqMode mode) {
    if (state.mode == mode) return;
    state = state.copyWith(mode: mode);
  }

  void setGraphicGainDb(int index, double gainDb) {
    final clamped = gainDb.clamp(gainMinDb, gainMaxDb).toDouble();
    final next = List<double>.of(state.graphicGainsDb);
    next[index] = clamped;
    state = state.copyWith(graphicGainsDb: next, clearActivePresetName: true);
    ref.read(eqGraphRepaintControllerProvider).bump();
  }

  void resetGraphic() {
    state = state.copyWith(
      graphicGainsDb: List<double>.filled(10, 0.0, growable: false),
      clearActivePresetName: true,
    );
    ref.read(eqGraphRepaintControllerProvider).bump();
  }

  void setParamBandEnabled(int index, bool enabled) {
    final next = List<ParametricBand>.of(state.parametricBands);
    next[index] = next[index].copyWith(enabled: enabled);
    state = state.copyWith(parametricBands: next, clearActivePresetName: true);
    ref.read(eqGraphRepaintControllerProvider).bump();
  }

  void setParamBandFreqHz(int index, double hz) {
    final clamped = hz.clamp(20.0, 20000.0).toDouble();
    final next = List<ParametricBand>.of(state.parametricBands);
    next[index] = next[index].copyWith(frequencyHz: clamped);
    state = state.copyWith(parametricBands: next, clearActivePresetName: true);
    ref.read(eqGraphRepaintControllerProvider).bump();
  }

  void setParamBandGainDb(int index, double gainDb) {
    final clamped = gainDb.clamp(gainMinDb, gainMaxDb).toDouble();
    final next = List<ParametricBand>.of(state.parametricBands);
    next[index] = next[index].copyWith(gainDb: clamped);
    state = state.copyWith(parametricBands: next, clearActivePresetName: true);
    ref.read(eqGraphRepaintControllerProvider).bump();
  }

  void setParamBandQ(int index, double q) {
    final clamped = q.clamp(0.2, 10.0).toDouble();
    final next = List<ParametricBand>.of(state.parametricBands);
    next[index] = next[index].copyWith(q: clamped);
    state = state.copyWith(parametricBands: next, clearActivePresetName: true);
    ref.read(eqGraphRepaintControllerProvider).bump();
  }

  void resetParametric() {
    state = state.copyWith(
      parametricBands: List<ParametricBand>.generate(
        5,
        (i) => ParametricBand(
          frequencyHz: EqualizerState.defaultParametricFrequenciesHz[i],
        ),
        growable: false,
      ),
      clearActivePresetName: true,
    );
    ref.read(eqGraphRepaintControllerProvider).bump();
  }

  void addParametricBand() {
    if (state.parametricBands.length >= maxParametricBands) {
      return;
    }

    final current = state.parametricBands;
    final lastFreq = current.isNotEmpty ? current.last.frequencyHz : 1000.0;
    final suggested = (lastFreq * 2).clamp(20.0, 20000.0).toDouble();

    final next = List<ParametricBand>.of(current)
      ..add(ParametricBand(frequencyHz: suggested));

    state = state.copyWith(parametricBands: next, clearActivePresetName: true);
    ref.read(eqGraphRepaintControllerProvider).bump();
  }

  void applyPreset({
    required String presetName,
    required bool enabled,
    required EqMode mode,
    required List<double> graphicGainsDb,
    required List<ParametricBand> parametricBands,
  }) {
    state = state.copyWith(
      enabled: enabled,
      mode: mode,
      graphicGainsDb: List<double>.of(graphicGainsDb, growable: false),
      parametricBands: List<ParametricBand>.of(
        parametricBands,
        growable: false,
      ),
      activePresetName: presetName,
    );
    ref.read(eqGraphRepaintControllerProvider).bump();
  }
}

final equalizerProvider = NotifierProvider<EqualizerNotifier, EqualizerState>(
  EqualizerNotifier.new,
);

// ============================================================================
// Granular selectors for smooth rebuilds
// ============================================================================

final eqEnabledProvider = Provider<bool>((ref) {
  return ref.watch(equalizerProvider.select((s) => s.enabled));
});

final eqModeProvider = Provider<EqMode>((ref) {
  return ref.watch(equalizerProvider.select((s) => s.mode));
});

final eqActivePresetNameProvider = Provider<String?>((ref) {
  return ref.watch(equalizerProvider.select((s) => s.activePresetName));
});

final eqGraphicGainDbProvider = Provider.family<double, int>((ref, index) {
  return ref.watch(equalizerProvider.select((s) => s.graphicGainsDb[index]));
});

final eqParamBandProvider = Provider.family<ParametricBand, int>((ref, index) {
  return ref.watch(equalizerProvider.select((s) => s.parametricBands[index]));
});
