/// Parsed log track entry.
class RipLogTrack {
  final int trackNumber;
  final String? status;
  final String? testCrc;
  final String? copyCrc;
  final bool? accurate;

  const RipLogTrack({
    required this.trackNumber,
    this.status,
    this.testCrc,
    this.copyCrc,
    this.accurate,
  });
}

/// Parsed rip log metadata.
class RipLog {
  final String? ripper;
  final String? readMode;
  final String? accurateStream;
  final String? defeatAudioCache;
  final String? useC2Pointers;
  final String? drive;
  final String? driveOffset;
  final bool? accurateRipEnabled;
  final List<RipLogTrack> tracks;

  const RipLog({
    this.ripper,
    this.readMode,
    this.accurateStream,
    this.defeatAudioCache,
    this.useC2Pointers,
    this.drive,
    this.driveOffset,
    this.accurateRipEnabled,
    required this.tracks,
  });
}

/// Service for parsing EAC and XLD rip logs.
class RipLogService {
  /// Parse a rip log from raw text.
  RipLog? parseLog(String content) {
    final normalized = content
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceFirst(RegExp(r'^\uFEFF'), '');

    final isEac = normalized.contains('Exact Audio Copy');
    final isXld = normalized.contains('X Lossless Decoder') ||
        normalized.contains('XLD');

    if (!isEac && !isXld) {
      // Try generic detection
      if (!normalized.contains('Track') &&
          !normalized.contains('CRC')) {
        return null;
      }
    }

    String? ripper;
    String? readMode;
    String? accurateStream;
    String? defeatAudioCache;
    String? useC2Pointers;
    String? drive;
    String? driveOffset;
    bool? accurateRipEnabled;

    if (isEac) {
      ripper = 'Exact Audio Copy';
      final readModeMatch = RegExp(
        r'Read mode\s*:\s*(.+)',
        caseSensitive: false,
      ).firstMatch(normalized);
      readMode = readModeMatch?.group(1)?.trim();

      final accurateStreamMatch = RegExp(
        r'Utilize accurate stream\s*:\s*(.+)',
        caseSensitive: false,
      ).firstMatch(normalized);
      accurateStream = accurateStreamMatch?.group(1)?.trim();

      final cacheMatch = RegExp(
        r'Defeat audio cache\s*:\s*(.+)',
        caseSensitive: false,
      ).firstMatch(normalized);
      defeatAudioCache = cacheMatch?.group(1)?.trim();

      final c2Match = RegExp(
        r'Make use of C2 pointers\s*:\s*(.+)',
        caseSensitive: false,
      ).firstMatch(normalized);
      useC2Pointers = c2Match?.group(1)?.trim();

      final driveMatch = RegExp(
        r'Used drive\s*:\s*(.+)',
        caseSensitive: false,
      ).firstMatch(normalized);
      drive = driveMatch?.group(1)?.trim();

      final offsetMatch = RegExp(
        r'Read offset correction\s*:\s*([+-]?\d+)',
        caseSensitive: false,
      ).firstMatch(normalized);
      driveOffset = offsetMatch?.group(1)?.trim();

      accurateRipEnabled = normalized.contains('AccurateRip: enabled') ||
          normalized.contains('AccurateRip summary');
    } else if (isXld) {
      ripper = 'X Lossless Decoder';
      final readModeMatch = RegExp(
        r'Ripper mode\s*:\s*(.+)',
        caseSensitive: false,
      ).firstMatch(normalized);
      readMode = readModeMatch?.group(1)?.trim();

      final cacheMatch = RegExp(
        r'Strategy\s*:\s*(.+)',
        caseSensitive: false,
      ).firstMatch(normalized);
      defeatAudioCache = cacheMatch?.group(1)?.trim();

      accurateRipEnabled = normalized.contains('AccurateRip') ||
          normalized.contains('accuraterip');
    }

    final tracks = <RipLogTrack>[];
    final trackPattern = RegExp(
      r'Track\s+(\d+)\s*\n',
      caseSensitive: false,
    );
    final trackMatches = trackPattern.allMatches(normalized).toList();

    for (var i = 0; i < trackMatches.length; i++) {
      final match = trackMatches[i];
      final trackNum = int.tryParse(match.group(1) ?? '') ?? (i + 1);
      final start = match.start;
      final end = i < trackMatches.length - 1
          ? trackMatches[i + 1].start
          : normalized.length;
      final block = normalized.substring(start, end);

      String? testCrc;
      String? copyCrc;
      String? status;
      bool? accurate;

      final testCrcMatch = RegExp(
        r'Test CRC\s*[:\s]+([0-9A-Fa-f]{8})',
        caseSensitive: false,
      ).firstMatch(block);
      testCrc = testCrcMatch?.group(1);

      final copyCrcMatch = RegExp(
        r'Copy CRC\s*[:\s]+([0-9A-Fa-f]{8})',
        caseSensitive: false,
      ).firstMatch(block);
      copyCrc = copyCrcMatch?.group(1);

      final statusMatch = RegExp(
        r'Track status\s*[:\s]+(.+)',
        caseSensitive: false,
      ).firstMatch(block);
      status = statusMatch?.group(1)?.trim();

      if (status == null) {
        if (block.contains('Accurately ripped')) {
          status = 'Accurately ripped';
          accurate = true;
        } else if (block.contains('Suspicious position')) {
          status = 'Suspicious';
          accurate = false;
        } else if (block.contains('Cannot be verified')) {
          status = 'Cannot be verified';
          accurate = false;
        }
      }

      accurate ??= testCrc != null &&
          copyCrc != null &&
          testCrc.toLowerCase() == copyCrc.toLowerCase();

      tracks.add(
        RipLogTrack(
          trackNumber: trackNum,
          status: status,
          testCrc: testCrc,
          copyCrc: copyCrc,
          accurate: accurate,
        ),
      );
    }

    if (tracks.isEmpty) return null;

    return RipLog(
      ripper: ripper,
      readMode: readMode,
      accurateStream: accurateStream,
      defeatAudioCache: defeatAudioCache,
      useC2Pointers: useC2Pointers,
      drive: drive,
      driveOffset: driveOffset,
      accurateRipEnabled: accurateRipEnabled,
      tracks: tracks,
    );
  }
}
