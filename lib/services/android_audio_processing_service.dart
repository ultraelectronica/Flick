import 'package:flutter/services.dart';
import 'package:flick/providers/equalizer_provider.dart';

const MethodChannel _androidAudioProcessingChannel = MethodChannel(
  'com.ultraelectronica.flick/equalizer',
);

final AndroidJustAudioProcessingService androidJustAudioProcessingService =
    AndroidJustAudioProcessingService();

class AndroidJustAudioProcessingService {
  AndroidJustAudioProcessingService({MethodChannel? channel})
    : _channel = channel ?? _androidAudioProcessingChannel;

  static const double _dbEpsilon = 0.01;

  final MethodChannel _channel;

  Future<void> apply({
    required EqualizerState state,
    required List<double> gainsDb,
    required int? audioSessionId,
    required bool bypassed,
  }) async {
    final request = _AndroidAudioProcessingRequest.fromState(
      state: state,
      gainsDb: gainsDb,
      audioSessionId: audioSessionId,
      bypassed: bypassed,
    );

    if (request.requiresAudioSession && audioSessionId == null) {
      return;
    }

    await _channel.invokeMethod<void>('applyAudioProcessing', request.toMap());
  }
}

class _AndroidAudioProcessingRequest {
  const _AndroidAudioProcessingRequest({
    required this.masterEnabled,
    required this.audioSessionId,
    required this.gainsDb,
    required this.compressor,
    required this.limiter,
    required this.fx,
  });

  factory _AndroidAudioProcessingRequest.fromState({
    required EqualizerState state,
    required List<double> gainsDb,
    required int? audioSessionId,
    required bool bypassed,
  }) {
    final masterEnabled = state.enabled && !bypassed;

    return _AndroidAudioProcessingRequest(
      masterEnabled: masterEnabled,
      audioSessionId: audioSessionId,
      gainsDb: List<double>.unmodifiable(gainsDb),
      compressor: _AndroidCompressorPayload.fromSettings(
        state.compressor,
        enabled: masterEnabled && state.compressor.enabled,
      ),
      limiter: _AndroidLimiterPayload.fromSettings(
        state.limiter,
        enabled: masterEnabled && state.limiter.enabled,
      ),
      fx: _AndroidFxPayload.fromSettings(
        state.fx,
        enabled: masterEnabled && state.fx.enabled,
      ),
    );
  }

  final bool masterEnabled;
  final int? audioSessionId;
  final List<double> gainsDb;
  final _AndroidCompressorPayload compressor;
  final _AndroidLimiterPayload limiter;
  final _AndroidFxPayload fx;

  bool get hasEqualizer => gainsDb.any(
    (gain) => gain.abs() >= AndroidJustAudioProcessingService._dbEpsilon,
  );

  bool get requiresAudioSession =>
      hasEqualizer ||
      compressor.enabled ||
      limiter.enabled ||
      fx.hasNativeCounterpart;

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'masterEnabled': masterEnabled,
      'audioSessionId': audioSessionId,
      'gainsDb': gainsDb,
      'compressor': compressor.toMap(),
      'limiter': limiter.toMap(),
      'fx': fx.toMap(),
    };
  }
}

class _AndroidCompressorPayload {
  const _AndroidCompressorPayload({
    required this.enabled,
    required this.thresholdDb,
    required this.ratio,
    required this.attackMs,
    required this.releaseMs,
    required this.makeupGainDb,
  });

  factory _AndroidCompressorPayload.fromSettings(
    CompressorSettings settings, {
    required bool enabled,
  }) {
    return _AndroidCompressorPayload(
      enabled: enabled,
      thresholdDb: settings.thresholdDb,
      ratio: settings.ratio,
      attackMs: settings.attackMs,
      releaseMs: settings.releaseMs,
      makeupGainDb: settings.makeupGainDb,
    );
  }

  final bool enabled;
  final double thresholdDb;
  final double ratio;
  final double attackMs;
  final double releaseMs;
  final double makeupGainDb;

  Map<String, Object> toMap() {
    return <String, Object>{
      'enabled': enabled,
      'thresholdDb': thresholdDb,
      'ratio': ratio,
      'attackMs': attackMs,
      'releaseMs': releaseMs,
      'makeupGainDb': makeupGainDb,
    };
  }
}

class _AndroidLimiterPayload {
  const _AndroidLimiterPayload({
    required this.enabled,
    required this.inputGainDb,
    required this.ceilingDb,
    required this.releaseMs,
  });

  factory _AndroidLimiterPayload.fromSettings(
    LimiterSettings settings, {
    required bool enabled,
  }) {
    return _AndroidLimiterPayload(
      enabled: enabled,
      inputGainDb: settings.inputGainDb,
      ceilingDb: settings.ceilingDb,
      releaseMs: settings.releaseMs,
    );
  }

  final bool enabled;
  final double inputGainDb;
  final double ceilingDb;
  final double releaseMs;

  Map<String, Object> toMap() {
    return <String, Object>{
      'enabled': enabled,
      'inputGainDb': inputGainDb,
      'ceilingDb': ceilingDb,
      'releaseMs': releaseMs,
    };
  }
}

class _AndroidFxPayload {
  const _AndroidFxPayload({
    required this.enabled,
    required this.balance,
    required this.tempo,
    required this.damp,
    required this.filterHz,
    required this.delayMs,
    required this.size,
    required this.mix,
    required this.feedback,
    required this.width,
  });

  factory _AndroidFxPayload.fromSettings(
    FxSettings settings, {
    required bool enabled,
  }) {
    return _AndroidFxPayload(
      enabled: enabled,
      balance: settings.balance,
      tempo: settings.tempo,
      damp: settings.damp,
      filterHz: settings.filterHz,
      delayMs: settings.delayMs,
      size: settings.size,
      mix: settings.mix,
      feedback: settings.feedback,
      width: settings.width,
    );
  }

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

  bool get usesReverb => enabled && mix > 0.01;

  bool get usesBalance => enabled && balance.abs() > 0.01;

  bool get usesVirtualizer => enabled && width > 1.01;

  bool get hasNativeCounterpart => usesBalance || usesReverb || usesVirtualizer;

  Map<String, Object> toMap() {
    return <String, Object>{
      'enabled': enabled,
      'balance': balance,
      'tempo': tempo,
      'damp': damp,
      'filterHz': filterHz,
      'delayMs': delayMs,
      'size': size,
      'mix': mix,
      'feedback': feedback,
      'width': width,
    };
  }
}
