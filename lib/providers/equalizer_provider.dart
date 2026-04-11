import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/services/equalizer_service.dart';

enum EqMode { graphic, parametric }

enum ParametricBandType {
  peaking,
  lowShelf,
  highShelf,
  lowPass,
  highPass,
  bandPass,
  notch,
  allPass,
}

extension ParametricBandTypeX on ParametricBandType {
  String get displayName {
    switch (this) {
      case ParametricBandType.peaking:
        return 'Peaking';
      case ParametricBandType.lowShelf:
        return 'Low Shelf';
      case ParametricBandType.highShelf:
        return 'High Shelf';
      case ParametricBandType.lowPass:
        return 'Low Pass';
      case ParametricBandType.highPass:
        return 'High Pass';
      case ParametricBandType.bandPass:
        return 'Band Pass';
      case ParametricBandType.notch:
        return 'Notch';
      case ParametricBandType.allPass:
        return 'All Pass';
    }
  }

  bool get supportsGain {
    switch (this) {
      case ParametricBandType.peaking:
      case ParametricBandType.lowShelf:
      case ParametricBandType.highShelf:
      case ParametricBandType.notch:
        return true;
      case ParametricBandType.lowPass:
      case ParametricBandType.highPass:
      case ParametricBandType.bandPass:
      case ParametricBandType.allPass:
        return false;
    }
  }

  String get qLabel {
    switch (this) {
      case ParametricBandType.lowShelf:
      case ParametricBandType.highShelf:
        return 'Slope';
      case ParametricBandType.lowPass:
      case ParametricBandType.highPass:
      case ParametricBandType.bandPass:
      case ParametricBandType.notch:
      case ParametricBandType.allPass:
        return 'Resonance';
      case ParametricBandType.peaking:
        return 'Q';
    }
  }
}

@immutable
class CompressorSettings {
  final bool enabled;
  final double thresholdDb;
  final double ratio;
  final double attackMs;
  final double releaseMs;
  final double makeupGainDb;

  const CompressorSettings({
    this.enabled = false,
    this.thresholdDb = -18.0,
    this.ratio = 3.0,
    this.attackMs = 12.0,
    this.releaseMs = 140.0,
    this.makeupGainDb = 0.0,
  });

  CompressorSettings copyWith({
    bool? enabled,
    double? thresholdDb,
    double? ratio,
    double? attackMs,
    double? releaseMs,
    double? makeupGainDb,
  }) {
    return CompressorSettings(
      enabled: enabled ?? this.enabled,
      thresholdDb: thresholdDb ?? this.thresholdDb,
      ratio: ratio ?? this.ratio,
      attackMs: attackMs ?? this.attackMs,
      releaseMs: releaseMs ?? this.releaseMs,
      makeupGainDb: makeupGainDb ?? this.makeupGainDb,
    );
  }
}

@immutable
class LimiterSettings {
  final bool enabled;
  final double inputGainDb;
  final double ceilingDb;
  final double releaseMs;

  const LimiterSettings({
    this.enabled = false,
    this.inputGainDb = 0.0,
    this.ceilingDb = -0.8,
    this.releaseMs = 80.0,
  });

  LimiterSettings copyWith({
    bool? enabled,
    double? inputGainDb,
    double? ceilingDb,
    double? releaseMs,
  }) {
    return LimiterSettings(
      enabled: enabled ?? this.enabled,
      inputGainDb: inputGainDb ?? this.inputGainDb,
      ceilingDb: ceilingDb ?? this.ceilingDb,
      releaseMs: releaseMs ?? this.releaseMs,
    );
  }
}

@immutable
class FxSettings {
  final bool enabled;
  final double balance;
  final double tempo;
  final double damp;
  final double filterHz;
  final double delayMs;
  final double size;
  final double mix;
  final double feedback;
  final double width;

  const FxSettings({
    this.enabled = false,
    this.balance = 0.0,
    this.tempo = 1.0,
    this.damp = 0.35,
    this.filterHz = 6800.0,
    this.delayMs = 240.0,
    this.size = 0.55,
    this.mix = 0.25,
    this.feedback = 0.35,
    this.width = 1.0,
  });

  FxSettings copyWith({
    bool? enabled,
    double? balance,
    double? tempo,
    double? damp,
    double? filterHz,
    double? delayMs,
    double? size,
    double? mix,
    double? feedback,
    double? width,
  }) {
    return FxSettings(
      enabled: enabled ?? this.enabled,
      balance: balance ?? this.balance,
      tempo: tempo ?? this.tempo,
      damp: damp ?? this.damp,
      filterHz: filterHz ?? this.filterHz,
      delayMs: delayMs ?? this.delayMs,
      size: size ?? this.size,
      mix: mix ?? this.mix,
      feedback: feedback ?? this.feedback,
      width: width ?? this.width,
    );
  }
}

@immutable
class ParametricBand {
  final bool enabled;
  final double frequencyHz; // 20..20000
  final double gainDb; // -12..+12 (UI only)
  final double q; // 0.2..10
  final ParametricBandType type;

  const ParametricBand({
    this.enabled = true,
    required this.frequencyHz,
    this.gainDb = 0.0,
    this.q = 1.0,
    this.type = ParametricBandType.peaking,
  });

  ParametricBand copyWith({
    bool? enabled,
    double? frequencyHz,
    double? gainDb,
    double? q,
    ParametricBandType? type,
  }) {
    return ParametricBand(
      enabled: enabled ?? this.enabled,
      frequencyHz: frequencyHz ?? this.frequencyHz,
      gainDb: gainDb ?? this.gainDb,
      q: q ?? this.q,
      type: type ?? this.type,
    );
  }
}

const double _passFilterDepthDb = 12.0;

double _sigmoid(double x) => 1.0 / (1.0 + math.exp(-x));

double _bandSigma(double q) => (0.55 / q.clamp(0.2, 10.0)).clamp(0.04, 1.2);

double parametricBandContributionDb({
  required ParametricBand band,
  required double hz,
}) {
  if (!band.enabled) return 0.0;

  final safeHz = hz.clamp(20.0, 20000.0).toDouble();
  final centerHz = band.frequencyHz.clamp(20.0, 20000.0).toDouble();
  final sigma = _bandSigma(band.q);
  final x = math.log(safeHz / centerHz);
  final gaussian = math.exp(-(x * x) / (2.0 * sigma * sigma));

  switch (band.type) {
    case ParametricBandType.peaking:
      return band.gainDb * gaussian;
    case ParametricBandType.lowShelf:
      return band.gainDb * _sigmoid(-x / sigma);
    case ParametricBandType.highShelf:
      return band.gainDb * _sigmoid(x / sigma);
    case ParametricBandType.lowPass:
      return -_passFilterDepthDb * _sigmoid(x / sigma);
    case ParametricBandType.highPass:
      return -_passFilterDepthDb * _sigmoid(-x / sigma);
    case ParametricBandType.bandPass:
      return -_passFilterDepthDb * (1.0 - gaussian);
    case ParametricBandType.notch:
      final depth = band.gainDb.abs().clamp(0.0, 12.0).toDouble();
      return -depth * gaussian;
    case ParametricBandType.allPass:
      return 0.0;
  }
}

double parametricResponseDbAtHz({
  required double hz,
  required List<ParametricBand> bands,
  double minDb = -12.0,
  double maxDb = 12.0,
}) {
  double sum = 0.0;
  for (final band in bands) {
    sum += parametricBandContributionDb(band: band, hz: hz);
  }
  return sum.clamp(minDb, maxDb).toDouble();
}

double parametricBandMarkerDb(ParametricBand band) {
  return parametricBandContributionDb(
    band: band,
    hz: band.frequencyHz,
  ).clamp(-12.0, 12.0).toDouble();
}

@immutable
class EqualizerState {
  final bool enabled;
  final EqMode mode;
  final double preampDb;

  /// Graphic EQ band gains in dB (UI only).
  final List<double> graphicGainsDb; // length = 10

  /// Parametric bands (UI only).
  /// Starts with 5 bands but can grow up to a configurable maximum.
  final List<ParametricBand> parametricBands;

  /// Active preset name (optional display).
  final String? activePresetName;

  final CompressorSettings compressor;
  final LimiterSettings limiter;
  final FxSettings fx;

  const EqualizerState({
    this.enabled = true,
    this.mode = EqMode.graphic,
    this.preampDb = 0.0,
    required this.graphicGainsDb,
    required this.parametricBands,
    this.activePresetName,
    this.compressor = const CompressorSettings(),
    this.limiter = const LimiterSettings(),
    this.fx = const FxSettings(),
  });

  EqualizerState copyWith({
    bool? enabled,
    EqMode? mode,
    double? preampDb,
    List<double>? graphicGainsDb,
    List<ParametricBand>? parametricBands,
    String? activePresetName,
    CompressorSettings? compressor,
    LimiterSettings? limiter,
    FxSettings? fx,
    bool clearActivePresetName = false,
  }) {
    return EqualizerState(
      enabled: enabled ?? this.enabled,
      mode: mode ?? this.mode,
      preampDb: preampDb ?? this.preampDb,
      graphicGainsDb: graphicGainsDb ?? this.graphicGainsDb,
      parametricBands: parametricBands ?? this.parametricBands,
      activePresetName: clearActivePresetName
          ? null
          : (activePresetName ?? this.activePresetName),
      compressor: compressor ?? this.compressor,
      limiter: limiter ?? this.limiter,
      fx: fx ?? this.fx,
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
      preampDb: 0.0,
      graphicGainsDb: List<double>.filled(10, 0.0, growable: false),
      parametricBands: List<ParametricBand>.generate(
        5,
        (i) => ParametricBand(frequencyHz: defaultParametricFrequenciesHz[i]),
        growable: false,
      ),
      activePresetName: null,
      compressor: const CompressorSettings(),
      limiter: const LimiterSettings(),
      fx: const FxSettings(),
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
  static const double preampMinDb = -24.0;
  static const double preampMaxDb = 24.0;
  static const double compressorThresholdMinDb = -36.0;
  static const double compressorThresholdMaxDb = 0.0;
  static const double compressorRatioMin = 1.0;
  static const double compressorRatioMax = 12.0;
  static const double compressorAttackMinMs = 1.0;
  static const double compressorAttackMaxMs = 100.0;
  static const double compressorReleaseMinMs = 20.0;
  static const double compressorReleaseMaxMs = 500.0;
  static const double limiterInputGainMinDb = 0.0;
  static const double limiterInputGainMaxDb = 12.0;
  static const double limiterCeilingMinDb = -12.0;
  static const double limiterCeilingMaxDb = 0.0;
  static const double limiterReleaseMinMs = 20.0;
  static const double limiterReleaseMaxMs = 300.0;
  static const double fxBalanceMin = -1.0;
  static const double fxBalanceMax = 1.0;
  static const double fxTempoMin = 0.5;
  static const double fxTempoMax = 2.0;
  static const double fxDampMin = 0.0;
  static const double fxDampMax = 1.0;
  static const double fxFilterMinHz = 200.0;
  static const double fxFilterMaxHz = 18000.0;
  static const double fxDelayMinMs = 10.0;
  static const double fxDelayMaxMs = 1600.0;
  static const double fxSizeMin = 0.0;
  static const double fxSizeMax = 1.0;
  static const double fxMixMin = 0.0;
  static const double fxMixMax = 1.0;
  static const double fxFeedbackMin = 0.0;
  static const double fxFeedbackMax = 0.95;
  static const double fxWidthMin = 0.0;
  static const double fxWidthMax = 2.0;
  static const int maxParametricBands = 10;

  @override
  EqualizerState build() {
    final initialState = EqualizerState.initial();
    // Sync to audio once after build (e.g. on desktop; on Android needs playback started first)
    Future.microtask(() => applyEqualizer(initialState));
    return initialState;
  }

  void _syncToAudio() {
    applyEqualizer(state).ignore();
  }

  void setEnabled(bool value) {
    state = state.copyWith(enabled: value);
    ref.read(eqGraphRepaintControllerProvider).bump();
    _syncToAudio();
  }

  void setMode(EqMode mode) {
    if (state.mode == mode) return;
    state = state.copyWith(mode: mode);
    _syncToAudio();
  }

  void setGraphicGainDb(int index, double gainDb) {
    final clamped = gainDb.clamp(gainMinDb, gainMaxDb).toDouble();
    final next = List<double>.of(state.graphicGainsDb);
    next[index] = clamped;
    state = state.copyWith(graphicGainsDb: next, clearActivePresetName: true);
    ref.read(eqGraphRepaintControllerProvider).bump();
    _syncToAudio();
  }

  void resetGraphic() {
    state = state.copyWith(
      preampDb: 0.0,
      graphicGainsDb: List<double>.filled(10, 0.0, growable: false),
      clearActivePresetName: true,
    );
    ref.read(eqGraphRepaintControllerProvider).bump();
    _syncToAudio();
  }

  void setParamBandEnabled(int index, bool enabled) {
    final next = List<ParametricBand>.of(state.parametricBands);
    next[index] = next[index].copyWith(enabled: enabled);
    state = state.copyWith(parametricBands: next, clearActivePresetName: true);
    ref.read(eqGraphRepaintControllerProvider).bump();
    _syncToAudio();
  }

  void setParamBandFreqHz(int index, double hz) {
    final clamped = hz.clamp(20.0, 20000.0).toDouble();
    final next = List<ParametricBand>.of(state.parametricBands);
    next[index] = next[index].copyWith(frequencyHz: clamped);
    state = state.copyWith(parametricBands: next, clearActivePresetName: true);
    ref.read(eqGraphRepaintControllerProvider).bump();
    _syncToAudio();
  }

  void setParamBandGainDb(int index, double gainDb) {
    final clamped = gainDb.clamp(gainMinDb, gainMaxDb).toDouble();
    final next = List<ParametricBand>.of(state.parametricBands);
    next[index] = next[index].copyWith(gainDb: clamped);
    state = state.copyWith(parametricBands: next, clearActivePresetName: true);
    ref.read(eqGraphRepaintControllerProvider).bump();
    _syncToAudio();
  }

  void setParamBandQ(int index, double q) {
    final clamped = q.clamp(0.2, 10.0).toDouble();
    final next = List<ParametricBand>.of(state.parametricBands);
    next[index] = next[index].copyWith(q: clamped);
    state = state.copyWith(parametricBands: next, clearActivePresetName: true);
    ref.read(eqGraphRepaintControllerProvider).bump();
    _syncToAudio();
  }

  void setParamBandType(int index, ParametricBandType type) {
    final next = List<ParametricBand>.of(state.parametricBands);
    var updated = next[index].copyWith(type: type);
    if (type == ParametricBandType.notch && updated.gainDb > 0.0) {
      updated = updated.copyWith(gainDb: -updated.gainDb);
    }
    next[index] = updated;
    state = state.copyWith(parametricBands: next, clearActivePresetName: true);
    ref.read(eqGraphRepaintControllerProvider).bump();
    _syncToAudio();
  }

  void resetParametric() {
    state = state.copyWith(
      preampDb: 0.0,
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
    _syncToAudio();
  }

  void setCompressorEnabled(bool enabled) {
    state = state.copyWith(
      compressor: state.compressor.copyWith(enabled: enabled),
      clearActivePresetName: true,
    );
    _syncToAudio();
  }

  void setCompressorThresholdDb(double thresholdDb) {
    state = state.copyWith(
      compressor: state.compressor.copyWith(
        thresholdDb: thresholdDb
            .clamp(compressorThresholdMinDb, compressorThresholdMaxDb)
            .toDouble(),
      ),
      clearActivePresetName: true,
    );
    _syncToAudio();
  }

  void setCompressorRatio(double ratio) {
    state = state.copyWith(
      compressor: state.compressor.copyWith(
        ratio: ratio.clamp(compressorRatioMin, compressorRatioMax).toDouble(),
      ),
      clearActivePresetName: true,
    );
    _syncToAudio();
  }

  void setCompressorAttackMs(double attackMs) {
    state = state.copyWith(
      compressor: state.compressor.copyWith(
        attackMs: attackMs
            .clamp(compressorAttackMinMs, compressorAttackMaxMs)
            .toDouble(),
      ),
      clearActivePresetName: true,
    );
    _syncToAudio();
  }

  void setCompressorReleaseMs(double releaseMs) {
    state = state.copyWith(
      compressor: state.compressor.copyWith(
        releaseMs: releaseMs
            .clamp(compressorReleaseMinMs, compressorReleaseMaxMs)
            .toDouble(),
      ),
      clearActivePresetName: true,
    );
    _syncToAudio();
  }

  void setCompressorMakeupGainDb(double makeupGainDb) {
    state = state.copyWith(
      compressor: state.compressor.copyWith(
        makeupGainDb: makeupGainDb.clamp(gainMinDb, gainMaxDb).toDouble(),
      ),
      clearActivePresetName: true,
    );
    _syncToAudio();
  }

  void setLimiterEnabled(bool enabled) {
    state = state.copyWith(
      limiter: state.limiter.copyWith(enabled: enabled),
      clearActivePresetName: true,
    );
    _syncToAudio();
  }

  void setLimiterInputGainDb(double inputGainDb) {
    state = state.copyWith(
      limiter: state.limiter.copyWith(
        inputGainDb: inputGainDb
            .clamp(limiterInputGainMinDb, limiterInputGainMaxDb)
            .toDouble(),
      ),
      clearActivePresetName: true,
    );
    _syncToAudio();
  }

  void setLimiterCeilingDb(double ceilingDb) {
    state = state.copyWith(
      limiter: state.limiter.copyWith(
        ceilingDb: ceilingDb
            .clamp(limiterCeilingMinDb, limiterCeilingMaxDb)
            .toDouble(),
      ),
      clearActivePresetName: true,
    );
    _syncToAudio();
  }

  void setLimiterReleaseMs(double releaseMs) {
    state = state.copyWith(
      limiter: state.limiter.copyWith(
        releaseMs: releaseMs
            .clamp(limiterReleaseMinMs, limiterReleaseMaxMs)
            .toDouble(),
      ),
      clearActivePresetName: true,
    );
    _syncToAudio();
  }

  void resetDynamics() {
    state = state.copyWith(
      compressor: const CompressorSettings(),
      limiter: const LimiterSettings(),
      clearActivePresetName: true,
    );
    _syncToAudio();
  }

  void setFxEnabled(bool enabled) {
    state = state.copyWith(
      fx: state.fx.copyWith(enabled: enabled),
      clearActivePresetName: true,
    );
    _syncToAudio();
  }

  void setFxBalance(double balance) {
    state = state.copyWith(
      fx: state.fx.copyWith(
        balance: balance.clamp(fxBalanceMin, fxBalanceMax).toDouble(),
      ),
      clearActivePresetName: true,
    );
    _syncToAudio();
  }

  void setFxTempo(double tempo) {
    state = state.copyWith(
      fx: state.fx.copyWith(
        tempo: tempo.clamp(fxTempoMin, fxTempoMax).toDouble(),
      ),
      clearActivePresetName: true,
    );
    _syncToAudio();
  }

  void setFxDamp(double damp) {
    state = state.copyWith(
      fx: state.fx.copyWith(damp: damp.clamp(fxDampMin, fxDampMax).toDouble()),
      clearActivePresetName: true,
    );
    _syncToAudio();
  }

  void setFxFilterHz(double filterHz) {
    state = state.copyWith(
      fx: state.fx.copyWith(
        filterHz: filterHz.clamp(fxFilterMinHz, fxFilterMaxHz).toDouble(),
      ),
      clearActivePresetName: true,
    );
    _syncToAudio();
  }

  void setFxDelayMs(double delayMs) {
    state = state.copyWith(
      fx: state.fx.copyWith(
        delayMs: delayMs.clamp(fxDelayMinMs, fxDelayMaxMs).toDouble(),
      ),
      clearActivePresetName: true,
    );
    _syncToAudio();
  }

  void setFxSize(double size) {
    state = state.copyWith(
      fx: state.fx.copyWith(size: size.clamp(fxSizeMin, fxSizeMax).toDouble()),
      clearActivePresetName: true,
    );
    _syncToAudio();
  }

  void setFxMix(double mix) {
    state = state.copyWith(
      fx: state.fx.copyWith(mix: mix.clamp(fxMixMin, fxMixMax).toDouble()),
      clearActivePresetName: true,
    );
    _syncToAudio();
  }

  void setFxFeedback(double feedback) {
    state = state.copyWith(
      fx: state.fx.copyWith(
        feedback: feedback.clamp(fxFeedbackMin, fxFeedbackMax).toDouble(),
      ),
      clearActivePresetName: true,
    );
    _syncToAudio();
  }

  void setFxWidth(double width) {
    state = state.copyWith(
      fx: state.fx.copyWith(
        width: width.clamp(fxWidthMin, fxWidthMax).toDouble(),
      ),
      clearActivePresetName: true,
    );
    _syncToAudio();
  }

  void resetFx() {
    state = state.copyWith(fx: const FxSettings(), clearActivePresetName: true);
    _syncToAudio();
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
    _syncToAudio();
  }

  void applyPreset({
    required String presetName,
    required bool enabled,
    required EqMode mode,
    double preampDb = 0.0,
    required List<double> graphicGainsDb,
    required List<ParametricBand> parametricBands,
    CompressorSettings compressor = const CompressorSettings(),
    LimiterSettings limiter = const LimiterSettings(),
    FxSettings fx = const FxSettings(),
  }) {
    state = state.copyWith(
      enabled: enabled,
      mode: mode,
      preampDb: preampDb.clamp(preampMinDb, preampMaxDb).toDouble(),
      graphicGainsDb: List<double>.of(graphicGainsDb, growable: false),
      parametricBands: List<ParametricBand>.of(
        parametricBands,
        growable: false,
      ),
      activePresetName: presetName,
      compressor: compressor,
      limiter: limiter,
      fx: fx,
    );
    ref.read(eqGraphRepaintControllerProvider).bump();
    _syncToAudio();
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

final eqCompressorProvider = Provider<CompressorSettings>((ref) {
  return ref.watch(equalizerProvider.select((s) => s.compressor));
});

final eqLimiterProvider = Provider<LimiterSettings>((ref) {
  return ref.watch(equalizerProvider.select((s) => s.limiter));
});

final eqFxProvider = Provider<FxSettings>((ref) {
  return ref.watch(equalizerProvider.select((s) => s.fx));
});
