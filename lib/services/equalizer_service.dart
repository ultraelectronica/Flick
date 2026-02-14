import 'package:flutter/foundation.dart';
import 'package:flick/providers/equalizer_provider.dart';
import 'package:flick/src/rust/api/audio_api.dart' as rust_audio;

/// Applies equalizer state to the active audio backend.
/// Rust engine (desktop): graphic EQ is applied. just_audio (Android): no-op for now.
void applyEqualizer(EqualizerState state) {
  if (!rust_audio.audioIsNativeAvailable() ||
      !rust_audio.audioIsInitialized()) {
    return;
  }
  final useGraphic = state.mode == EqMode.graphic;
  final gains = useGraphic
      ? state.graphicGainsDb
      : _parametricToGraphicGains(state.parametricBands);
  if (gains.length != 10) return;
  try {
    rust_audio.audioSetEqualizer(
      enabled: state.enabled,
      gainsDb: List<double>.from(gains),
    );
  } catch (e) {
    debugPrint('EqualizerService.apply failed: $e');
  }
}

/// Map parametric bands to 10-band gains for Rust engine (graphic-only).
List<double> _parametricToGraphicGains(List<ParametricBand> bands) {
  final out = List<double>.filled(10, 0.0, growable: false);
  final freqs = EqualizerState.defaultGraphicFrequenciesHz;
  for (var i = 0; i < 10; i++) {
    final f = freqs[i];
    for (final b in bands) {
      if (!b.enabled) continue;
      final dist = (b.frequencyHz - f).abs();
      final bw = b.frequencyHz / b.q;
      if (dist < bw) {
        final t = dist / bw;
        out[i] = out[i] + b.gainDb * (1.0 - t);
      }
    }
  }
  return out;
}
