import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flick/providers/equalizer_provider.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/src/rust/api/audio_api.dart' as rust_audio;

const MethodChannel _androidEqualizerChannel = MethodChannel(
  'com.ultraelectronica.flick/equalizer',
);

/// Applies equalizer state to the active audio backend.
/// Rust engine (desktop): graphic EQ is applied via Rust.
/// Android: uses native AudioEffect API with just_audio's audio session ID.
Future<void> applyEqualizer(EqualizerState state) async {
  final useGraphic = state.mode == EqMode.graphic;
  final gains = useGraphic
      ? state.graphicGainsDb
      : _parametricToGraphicGains(state.parametricBands);

  if (gains.length != 10) return;

  // Android: use native AudioEffect API with session ID from just_audio
  if (Platform.isAndroid) {
    final sessionId = PlayerService().androidAudioSessionId;
    if (sessionId == null && state.enabled) return;
    try {
      await _androidEqualizerChannel.invokeMethod('setEqualizer', {
        'enabled': state.enabled,
        'gainsDb': gains,
        'audioSessionId': sessionId,
      });
    } catch (_) {}
    return;
  }

  // Desktop: use Rust audio engine
  if (!rust_audio.audioIsNativeAvailable() ||
      !rust_audio.audioIsInitialized()) {
    return;
  }
  try {
    rust_audio.audioSetEqualizer(
      enabled: state.enabled,
      gainsDb: List<double>.from(gains),
    );
  } catch (_) {}
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
