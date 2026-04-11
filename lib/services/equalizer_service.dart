import 'dart:io';
import 'package:flick/providers/equalizer_provider.dart';
import 'package:flick/services/android_audio_processing_service.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/uac2_service.dart';
import 'package:flick/src/rust/api/audio_api.dart' as rust_audio;

EqualizerState _lastRequestedState = EqualizerState.initial();

/// Applies EQ and processing state to the active audio backend.
/// Rust engine: graphic EQ, dynamics, and creative FX are applied natively.
/// just_audio on Android: uses native AudioEffect counterparts where available.
Future<void> applyEqualizer(EqualizerState state) async {
  _lastRequestedState = _snapshotState(state);

  final useGraphic = state.mode == EqMode.graphic;
  final gains = _applyPreamp(
    gains: useGraphic
        ? state.graphicGainsDb
        : _parametricToGraphicGains(state.parametricBands),
    preampDb: state.preampDb,
  );

  if (gains.length != 10) return;

  final playerService = PlayerService();
  final useRustBackend =
      playerService.isUsingRustBackend &&
      rust_audio.audioIsNativeAvailable() &&
      rust_audio.audioIsInitialized();
  final bypassForBitPerfect =
      playerService.isBitPerfectProcessingLocked ||
      Uac2Service.instance.isBitPerfectEnabledSync;

  // Android + just_audio: use native AudioEffect counterparts with session ID.
  if (Platform.isAndroid && !useRustBackend) {
    try {
      await androidJustAudioProcessingService.apply(
        state: state,
        gainsDb: gains,
        audioSessionId: playerService.androidAudioSessionId,
        bypassed: bypassForBitPerfect,
      );
    } catch (_) {}
    return;
  }

  // Rust backend: apply EQ + compressor + limiter to the active native engine.
  if (!rust_audio.audioIsNativeAvailable() ||
      !rust_audio.audioIsInitialized()) {
    return;
  }
  try {
    if (bypassForBitPerfect) {
      rust_audio.audioSetEqualizer(
        enabled: false,
        gainsDb: List<double>.filled(10, 0.0, growable: false),
      );
      await rust_audio.audioSetCompressor(
        enabled: false,
        thresholdDb: state.compressor.thresholdDb,
        ratio: state.compressor.ratio,
        attackMs: state.compressor.attackMs,
        releaseMs: state.compressor.releaseMs,
        makeupGainDb: state.compressor.makeupGainDb,
      );
      await rust_audio.audioSetLimiter(
        enabled: false,
        inputGainDb: state.limiter.inputGainDb,
        ceilingDb: state.limiter.ceilingDb,
        releaseMs: state.limiter.releaseMs,
      );
      await rust_audio.audioSetFx(
        enabled: false,
        balance: state.fx.balance,
        tempo: state.fx.tempo,
        damp: state.fx.damp,
        filterHz: state.fx.filterHz,
        delayMs: state.fx.delayMs,
        size: state.fx.size,
        mix: state.fx.mix,
        feedback: state.fx.feedback,
        width: state.fx.width,
      );
      return;
    }

    rust_audio.audioSetEqualizer(
      enabled: state.enabled,
      gainsDb: List<double>.from(gains),
    );
    await rust_audio.audioSetCompressor(
      enabled: state.enabled && state.compressor.enabled,
      thresholdDb: state.compressor.thresholdDb,
      ratio: state.compressor.ratio,
      attackMs: state.compressor.attackMs,
      releaseMs: state.compressor.releaseMs,
      makeupGainDb: state.compressor.makeupGainDb,
    );
    await rust_audio.audioSetLimiter(
      enabled: state.enabled && state.limiter.enabled,
      inputGainDb: state.limiter.inputGainDb,
      ceilingDb: state.limiter.ceilingDb,
      releaseMs: state.limiter.releaseMs,
    );
    await rust_audio.audioSetFx(
      enabled: state.enabled && state.fx.enabled,
      balance: state.fx.balance,
      tempo: state.fx.tempo,
      damp: state.fx.damp,
      filterHz: state.fx.filterHz,
      delayMs: state.fx.delayMs,
      size: state.fx.size,
      mix: state.fx.mix,
      feedback: state.fx.feedback,
      width: state.fx.width,
    );
  } catch (_) {}
}

Future<void> reapplyEqualizer() async {
  await applyEqualizer(_lastRequestedState);
}

/// Map parametric bands to 10-band gains for Rust engine (graphic-only).
List<double> _parametricToGraphicGains(List<ParametricBand> bands) {
  final freqs = EqualizerState.defaultGraphicFrequenciesHz;
  return List<double>.generate(
    freqs.length,
    (i) => parametricResponseDbAtHz(hz: freqs[i], bands: bands),
    growable: false,
  );
}

EqualizerState _snapshotState(EqualizerState state) {
  return state.copyWith(
    preampDb: state.preampDb,
    graphicGainsDb: List<double>.of(state.graphicGainsDb, growable: false),
    parametricBands: List<ParametricBand>.of(
      state.parametricBands,
      growable: false,
    ),
    compressor: state.compressor.copyWith(),
    limiter: state.limiter.copyWith(),
    fx: state.fx.copyWith(),
  );
}

List<double> _applyPreamp({
  required List<double> gains,
  required double preampDb,
}) {
  if (preampDb == 0.0) {
    return List<double>.of(gains, growable: false);
  }
  return List<double>.generate(
    gains.length,
    (index) => gains[index] + preampDb,
    growable: false,
  );
}
