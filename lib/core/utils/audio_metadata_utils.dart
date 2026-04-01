/// Utilities for normalizing and formatting audio metadata values.
class AudioMetadataUtils {
  AudioMetadataUtils._();

  static const int _definitelyBitsPerSecondThreshold = 100000;

  /// Convert a bitrate reported in bits per second into kilobits per second.
  static int? bitrateFromBitsPerSecond(int? bitrate) {
    if (bitrate == null || bitrate <= 0) {
      return null;
    }
    return (bitrate / 1000).round();
  }

  /// Normalize stored bitrate values to kbps.
  ///
  /// Most rows should already be stored as kbps, but older Android scans may
  /// still contain raw bits-per-second values.
  static int? normalizeStoredBitrateKbps(
    int? bitrate, {
    int? sampleRate,
    int? bitDepth,
  }) {
    if (bitrate == null || bitrate <= 0) {
      return null;
    }

    if (_looksLikeLegacyBitsPerSecond(
      bitrate,
      sampleRate: sampleRate,
      bitDepth: bitDepth,
    )) {
      return bitrateFromBitsPerSecond(bitrate);
    }

    return bitrate;
  }

  /// Format a stored bitrate value as a human-readable label.
  static String? formatBitrateLabel(
    int? bitrate, {
    int? sampleRate,
    int? bitDepth,
  }) {
    final normalized = normalizeStoredBitrateKbps(
      bitrate,
      sampleRate: sampleRate,
      bitDepth: bitDepth,
    );
    if (normalized == null) {
      return null;
    }
    return '${normalized}kbps';
  }

  static bool _looksLikeLegacyBitsPerSecond(
    int bitrate, {
    int? sampleRate,
    int? bitDepth,
  }) {
    if (bitrate >= _definitelyBitsPerSecondThreshold) {
      return true;
    }

    if (bitrate <= 10000) {
      return false;
    }

    final estimatedStereoPcmKbps = _estimateStereoPcmKbps(
      sampleRate: sampleRate,
      bitDepth: bitDepth,
    );

    if (estimatedStereoPcmKbps == null) {
      return true;
    }

    return bitrate > estimatedStereoPcmKbps * 8;
  }

  static int? _estimateStereoPcmKbps({int? sampleRate, int? bitDepth}) {
    if (sampleRate == null ||
        sampleRate <= 0 ||
        bitDepth == null ||
        bitDepth <= 0) {
      return null;
    }

    return ((sampleRate * bitDepth * 2) / 1000).round();
  }
}
