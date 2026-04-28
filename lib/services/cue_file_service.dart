/// Parsed CUE sheet track.
class CueTrack {
  final int trackNumber;
  final String title;
  final String performer;
  final int startOffsetMs;
  final int? endOffsetMs;

  const CueTrack({
    required this.trackNumber,
    required this.title,
    required this.performer,
    required this.startOffsetMs,
    this.endOffsetMs,
  });
}

/// Parsed CUE sheet.
class CueSheet {
  final String? performer;
  final String? title;
  final String? date;
  final String? genre;
  final String audioFile;
  final List<CueTrack> tracks;

  const CueSheet({
    this.performer,
    this.title,
    this.date,
    this.genre,
    required this.audioFile,
    required this.tracks,
  });
}

/// Service for parsing CUE sheet files.
class CueFileService {
  static final RegExp _filePattern = RegExp(
    r'^FILE\s+"([^"]+)"\s+(WAVE|MP3|AIFF|BINARY|MOTOROLA)',
    caseSensitive: false,
  );
  static final RegExp _trackPattern = RegExp(
    r'^TRACK\s+(\d+)\s+AUDIO',
    caseSensitive: false,
  );
  static final RegExp _indexPattern = RegExp(
    r'^INDEX\s+(\d+)\s+(\d+):(\d+):(\d+)',
    caseSensitive: false,
  );
  static final RegExp _titlePattern = RegExp(
    r'^TITLE\s+"([^"]*)"',
    caseSensitive: false,
  );
  static final RegExp _performerPattern = RegExp(
    r'^PERFORMER\s+"([^"]*)"',
    caseSensitive: false,
  );
  static final RegExp _remDatePattern = RegExp(
    r'^REM\s+DATE\s+(\d+)',
    caseSensitive: false,
  );
  static final RegExp _remGenrePattern = RegExp(
    r'^REM\s+GENRE\s+"([^"]*)"',
    caseSensitive: false,
  );
  static final RegExp _remGenreBarePattern = RegExp(
    r'^REM\s+GENRE\s+(\S+)',
    caseSensitive: false,
  );

  /// Parse a CUE sheet from raw text.
  CueSheet? parseCueSheet(String content, {required String cueFilePath}) {
    final lines = content
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceFirst(RegExp(r'^\uFEFF'), '')
        .split('\n');

    String? globalPerformer;
    String? globalTitle;
    String? globalDate;
    String? globalGenre;
    String? currentAudioFile;

    final tracks = <CueTrack>[];
    String? currentTrackTitle;
    String? currentTrackPerformer;
    int? currentTrackNumber;
    int? currentTrackIndexMs;
    int? lastTrackIndexMs;

    for (var raw in lines) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith(';')) continue;

      final fileMatch = _filePattern.firstMatch(line);
      if (fileMatch != null) {
        currentAudioFile = fileMatch.group(1);
        continue;
      }

      final dateMatch = _remDatePattern.firstMatch(line);
      if (dateMatch != null) {
        globalDate = dateMatch.group(1);
        continue;
      }

      final genreMatch = _remGenrePattern.firstMatch(line);
      if (genreMatch != null) {
        globalGenre = genreMatch.group(1);
        continue;
      }

      final genreBareMatch = _remGenreBarePattern.firstMatch(line);
      if (genreBareMatch != null) {
        globalGenre = genreBareMatch.group(1);
        continue;
      }

      final titleMatch = _titlePattern.firstMatch(line);
      if (titleMatch != null) {
        if (currentTrackNumber != null) {
          currentTrackTitle = titleMatch.group(1);
        } else {
          globalTitle = titleMatch.group(1);
        }
        continue;
      }

      final performerMatch = _performerPattern.firstMatch(line);
      if (performerMatch != null) {
        if (currentTrackNumber != null) {
          currentTrackPerformer = performerMatch.group(1);
        } else {
          globalPerformer = performerMatch.group(1);
        }
        continue;
      }

      final trackMatch = _trackPattern.firstMatch(line);
      if (trackMatch != null) {
        // Finalize previous track
        if (currentTrackNumber != null &&
            lastTrackIndexMs != null &&
            currentTrackIndexMs != null) {
          tracks.add(
            CueTrack(
              trackNumber: currentTrackNumber,
              title: currentTrackTitle ?? 'Track $currentTrackNumber',
              performer: currentTrackPerformer ?? globalPerformer ?? '',
              startOffsetMs: currentTrackIndexMs,
              endOffsetMs: null,
            ),
          );
        }
        currentTrackNumber = int.tryParse(trackMatch.group(1) ?? '');
        currentTrackTitle = null;
        currentTrackPerformer = null;
        lastTrackIndexMs = currentTrackIndexMs;
        currentTrackIndexMs = null;
        continue;
      }

      final indexMatch = _indexPattern.firstMatch(line);
      if (indexMatch != null) {
        final minutes = int.tryParse(indexMatch.group(2) ?? '0') ?? 0;
        final seconds = int.tryParse(indexMatch.group(3) ?? '0') ?? 0;
        final frames = int.tryParse(indexMatch.group(4) ?? '0') ?? 0;
        final ms = (minutes * 60 + seconds) * 1000 + (frames * 1000 ~/ 75);
        if (currentTrackNumber != null) {
          final indexNum = int.tryParse(indexMatch.group(1) ?? '0') ?? 0;
          if (indexNum == 1) {
            currentTrackIndexMs = ms;
          }
        }
        continue;
      }
    }

    // Finalize last track
    if (currentTrackNumber != null &&
        currentTrackIndexMs != null) {
      tracks.add(
        CueTrack(
          trackNumber: currentTrackNumber,
          title: currentTrackTitle ?? 'Track $currentTrackNumber',
          performer: currentTrackPerformer ?? globalPerformer ?? '',
          startOffsetMs: currentTrackIndexMs,
          endOffsetMs: null,
        ),
      );
    }

    // Compute end offsets from next track starts
    for (var i = 0; i < tracks.length - 1; i++) {
      tracks[i] = CueTrack(
        trackNumber: tracks[i].trackNumber,
        title: tracks[i].title,
        performer: tracks[i].performer,
        startOffsetMs: tracks[i].startOffsetMs,
        endOffsetMs: tracks[i + 1].startOffsetMs,
      );
    }

    if (currentAudioFile == null || tracks.isEmpty) {
      return null;
    }

    return CueSheet(
      performer: globalPerformer,
      title: globalTitle,
      date: globalDate,
      genre: globalGenre,
      audioFile: currentAudioFile,
      tracks: tracks,
    );
  }

  /// Resolve the audio file path relative to the CUE file.
  String resolveAudioFilePath(String cueFilePath, String audioFile) {
    if (audioFile.contains('/') || audioFile.contains('\\')) {
      return audioFile;
    }
    final separator = cueFilePath.contains('\\') ? '\\' : '/';
    final lastSep = cueFilePath.lastIndexOf(separator);
    if (lastSep == -1) return audioFile;
    return cueFilePath.substring(0, lastSep + 1) + audioFile;
  }
}
