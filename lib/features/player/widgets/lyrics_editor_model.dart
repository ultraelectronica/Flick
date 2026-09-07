import 'package:flick/services/lyrics_service.dart';

/// One editable lyric row: text, an optional line timestamp, and optional
/// per-segment word start times for karaoke (enhanced LRC) editing.
///
/// A segment is one karaoke unit. Usually it is a whole token, but a token
/// can carry [segmentBreaks] — char offsets inside the token core where it
/// splits into separately timed syllables (e.g. "Hel|lo"). [wordStarts] is
/// aligned to the flat segment list; index `i` holds the start of segment
/// `i`, or null while it is still untapped. A null list means the line has
/// no word data at all.
class EditableLyricLine {
  final String text;
  final Duration? timestamp;
  final List<Duration?>? wordStarts;

  /// Per-token char offsets (exclusive segment ends within the token core,
  /// 1..coreLen-1, sorted). Null when no token is split.
  final List<List<int>>? segmentBreaks;

  const EditableLyricLine({
    required this.text,
    required this.timestamp,
    this.wordStarts,
    this.segmentBreaks,
  });

  List<String> get tokens => tokenizeLineText(text);

  int get tokenCount => tokens.length;

  int get segmentCount {
    final breaks = segmentBreaks;
    if (breaks == null) return tokenCount;
    var count = 0;
    final tokenList = tokens;
    for (var t = 0; t < tokenList.length; t++) {
      count += 1 + (t < breaks.length ? breaks[t].length : 0);
    }
    return count;
  }

  /// Flat segment list with each segment's token and char range inside the
  /// token core.
  List<({int tokenIndex, int charStart, int charEnd})> get segmentLayout {
    final tokenList = tokens;
    final breaks = segmentBreaks;
    final layout = <({int tokenIndex, int charStart, int charEnd})>[];
    for (var t = 0; t < tokenList.length; t++) {
      final coreLen = tokenList[t].trim().length;
      final bounds = <int>[
        0,
        if (breaks != null && t < breaks.length) ...breaks[t],
        coreLen,
      ];
      for (var j = 0; j + 1 < bounds.length; j++) {
        layout.add((
          tokenIndex: t,
          charStart: bounds[j],
          charEnd: bounds[j + 1],
        ));
      }
    }
    return layout;
  }

  /// Display text of segment [segmentIndex] (token core slice).
  String segmentLabel(int segmentIndex) {
    final layout = segmentLayout;
    if (segmentIndex < 0 || segmentIndex >= layout.length) return '';
    final token = tokens[layout[segmentIndex].tokenIndex];
    final core = token.trim();
    return core.substring(
      layout[segmentIndex].charStart,
      layout[segmentIndex].charEnd,
    );
  }

  bool get hasAnyWords => capturedWordCount > 0;

  bool get hasCompleteWords {
    final starts = wordStarts;
    if (starts == null || starts.isEmpty) return false;
    return starts.length == segmentCount && starts.every((s) => s != null);
  }

  int get capturedWordCount =>
      wordStarts?.where((s) => s != null).length ?? 0;

  EditableLyricLine copyWith({
    String? text,
    Duration? timestamp,
    bool clearTimestamp = false,
    List<Duration?>? wordStarts,
    bool clearWordStarts = false,
    List<List<int>>? segmentBreaks,
    bool clearSegmentBreaks = false,
  }) {
    return EditableLyricLine(
      text: text ?? this.text,
      timestamp: clearTimestamp ? null : (timestamp ?? this.timestamp),
      wordStarts: clearWordStarts ? null : (wordStarts ?? this.wordStarts),
      segmentBreaks: clearSegmentBreaks
          ? null
          : (segmentBreaks ?? this.segmentBreaks),
    );
  }

  /// Whitespace tokens of [text]. Concatenating the tokens reproduces the
  /// text exactly; leading whitespace attaches to the first token, trailing
  /// whitespace to the last one before it.
  static List<String> tokenizeLineText(String text) {
    final matches = LyricsService.tokenMatches(text);
    if (matches.isEmpty) return const [];
    return [
      for (var i = 0; i < matches.length; i++)
        (i == 0 ? text.substring(0, matches.first.start) : '') +
            (matches[i].group(0) ?? ''),
    ];
  }
}

/// Pure editor state for the lyrics sync studio. Every operation returns a
/// new model so the widget can keep using setState without mutation bugs.
class LyricsEditorModel {
  final List<EditableLyricLine> lines;

  const LyricsEditorModel(this.lines);

  factory LyricsEditorModel.fromLyrics(LyricsData? lyrics) {
    if (lyrics == null || lyrics.lines.isEmpty) {
      return const LyricsEditorModel([
        EditableLyricLine(text: '', timestamp: null),
      ]);
    }
    return LyricsEditorModel([
      for (final line in lyrics.lines)
        () {
          final seeded = _seedWordData(line);
          return EditableLyricLine(
            text: line.text,
            timestamp: lyrics.isSynchronized ? line.timestamp : null,
            wordStarts: seeded?.$1,
            segmentBreaks: seeded?.$2,
          );
        }(),
    ]);
  }

  int get usableLineCount =>
      lines.where((line) => line.text.trim().isNotEmpty).length;

  int get stampedLineCount => lines
      .where((line) => line.text.trim().isNotEmpty && line.timestamp != null)
      .length;

  int get capturedWordCount =>
      lines.fold<int>(0, (sum, line) => sum + line.capturedWordCount);

  int get totalWordCount =>
      lines.fold<int>(0, (sum, line) {
        final text = line.text.trim();
        return text.isEmpty ? 0 : line.segmentCount;
      });

  /// Rebuilds rows from the raw lyrics text field, carrying over timestamps
  /// and word data by row index. Word starts survive only when the edited
  /// row still has the same token count.
  LyricsEditorModel reflowText(String rawText) {
    final rows = rawText
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');

    final next = <EditableLyricLine>[];
    for (var index = 0; index < rows.length; index++) {
      final old = index < lines.length ? lines[index] : null;
      if (old == null) {
        next.add(EditableLyricLine(text: rows[index], timestamp: null));
        continue;
      }
      final (starts, breaks) = _remapWordData(old, rows[index]);
      next.add(
        EditableLyricLine(
          text: rows[index],
          timestamp: old.timestamp,
          wordStarts: starts,
          segmentBreaks: breaks,
        ),
      );
    }

    while (next.isNotEmpty && next.last.text.isEmpty) {
      next.removeLast();
    }
    if (next.isEmpty) {
      next.add(const EditableLyricLine(text: '', timestamp: null));
    }
    return LyricsEditorModel(next);
  }

  /// Moves every captured time (line stamps and word starts) by [delta].
  LyricsEditorModel shiftAll(Duration delta) {
    return LyricsEditorModel([
      for (final line in lines)
        line.copyWith(
          timestamp: line.timestamp == null
              ? null
              : _shiftClamped(line.timestamp!, delta),
          wordStarts: line.wordStarts == null
              ? null
              : [
                  for (final start in line.wordStarts!)
                    start == null ? null : _shiftClamped(start, delta),
                ],
        ),
    ]);
  }

  /// Sets or clears a line timestamp. Re-stamping shifts existing word
  /// starts by the same delta so their rhythm survives; clearing the stamp
  /// drops the word data too, since a line without a timestamp cannot keep
  /// karaoke timing meaningful.
  LyricsEditorModel setLineTimestamp(int index, Duration? timestamp) {
    if (index < 0 || index >= lines.length) return this;
    final current = lines[index];

    if (timestamp == null) {
      return _replace(
        index,
        current.copyWith(clearTimestamp: true, clearWordStarts: true),
      );
    }

    var next = current.copyWith(timestamp: timestamp);
    final starts = current.wordStarts;
    final old = current.timestamp;
    if (starts != null && old != null) {
      final delta = Duration(
        milliseconds: timestamp.inMilliseconds - old.inMilliseconds,
      );
      next = next.copyWith(
        wordStarts: [
          for (final start in starts)
            start == null ? null : _shiftClamped(start, delta),
        ],
      );
    }
    return _replace(index, next);
  }

  /// Stamps the next untapped word slot at [at]. The first tap of a line
  /// also becomes the line timestamp (A2 convention). Returns the stamped
  /// word index, or null when there was nothing left to stamp.
  (LyricsEditorModel, int?) stampNextWord(int lineIndex, Duration at) {
    final line = _lineAt(lineIndex);
    if (line == null) return (this, null);

    final tokens = line.tokens;
    if (tokens.isEmpty) return (this, null);

    var starts = line.wordStarts;
    if (starts == null || starts.length != line.segmentCount) {
      starts = List<Duration?>.filled(line.segmentCount, null);
    }
    final next = starts.indexWhere((start) => start == null);
    if (next < 0) return (this, null);

    final updated = List<Duration?>.of(starts)..[next] = at;
    var replaced = line.copyWith(wordStarts: updated);
    if (next == 0) {
      replaced = replaced.copyWith(timestamp: at);
    }
    return (_replace(lineIndex, replaced), next);
  }

  LyricsEditorModel undoLastWordStamp(int lineIndex) {
    final line = _lineAt(lineIndex);
    final starts = line?.wordStarts;
    if (line == null || starts == null) return this;

    var last = -1;
    for (var i = 0; i < starts.length; i++) {
      if (starts[i] != null) last = i;
    }
    if (last < 0) return this;

    final updated = List<Duration?>.of(starts)..[last] = null;
    return _replace(lineIndex, line.copyWith(wordStarts: updated));
  }

  /// Drops all word data for a line but keeps its line timestamp.
  LyricsEditorModel clearWords(int lineIndex) {
    final line = _lineAt(lineIndex);
    if (line == null) return this;
    return _replace(
      lineIndex,
      line.copyWith(clearWordStarts: true, clearSegmentBreaks: true),
    );
  }

  /// Clears a single tapped word slot, leaving the rest of the line intact.
  LyricsEditorModel clearWord(int lineIndex, int wordIndex) {
    final line = _lineAt(lineIndex);
    final starts = line?.wordStarts;
    if (line == null ||
        starts == null ||
        wordIndex < 0 ||
        wordIndex >= starts.length ||
        starts[wordIndex] == null) {
      return this;
    }
    final updated = List<Duration?>.of(starts)..[wordIndex] = null;
    return _replace(lineIndex, line.copyWith(wordStarts: updated));
  }

  LyricsEditorModel setWord(int lineIndex, int wordIndex, Duration at) {
    final line = _lineAt(lineIndex);
    final starts = line?.wordStarts;
    if (line == null ||
        starts == null ||
        wordIndex < 0 ||
        wordIndex >= starts.length) {
      return this;
    }

    final updated = List<Duration?>.of(starts)..[wordIndex] = at;
    var replaced = line.copyWith(wordStarts: updated);
    if (wordIndex == 0) {
      replaced = replaced.copyWith(timestamp: at);
    }
    return _replace(lineIndex, replaced);
  }

  LyricsEditorModel nudgeWord(
    int lineIndex,
    int wordIndex,
    Duration delta,
  ) {
    final line = _lineAt(lineIndex);
    final slot = line?.wordStarts;
    if (line == null ||
        slot == null ||
        wordIndex < 0 ||
        wordIndex >= slot.length ||
        slot[wordIndex] == null) {
      return this;
    }
    return setWord(
      lineIndex,
      wordIndex,
      _shiftClamped(slot[wordIndex]!, delta),
    );
  }

  /// Timeline window end for [lineIndex]: the first following row with a
  /// stamp (empty rows skipped), or a +5s fallback mirroring the
  /// renderer's line-end guess.
  Duration lineEndFor(int lineIndex) {
    final line = _lineAt(lineIndex);
    if (line == null) return Duration.zero;
    final base = _lastCapturedStart(line) ?? line.timestamp ?? Duration.zero;
    final nextIndex = _nextStampedIndex(lineIndex);
    if (nextIndex != null) {
      final next = lines[nextIndex].timestamp!;
      if (next > base) return next;
    }
    return base + const Duration(seconds: 5);
  }

  /// Draggable clip windows for a fully captured line: word `i` ends when
  /// word `i + 1` starts, and the last word runs to [lineEndFor]. Returns
  /// null unless the line's word starts are complete.
  List<({Duration start, Duration end})>? wordWindows(int lineIndex) {
    final line = _lineAt(lineIndex);
    final starts = line?.wordStarts;
    if (line == null || starts == null || !line.hasCompleteWords) return null;

    final windows = <({Duration start, Duration end})>[];
    for (var i = 0; i < starts.length; i++) {
      final start = starts[i]!;
      final Duration end;
      if (i + 1 < starts.length) {
        final next = starts[i + 1]!;
        end = next > start ? next : start;
      } else {
        final lineEnd = lineEndFor(lineIndex);
        end = lineEnd > start ? lineEnd : start;
      }
      windows.add((start: start, end: end));
    }
    return windows;
  }

  /// Moves a word boundary (the start of [wordIndex], shared with the
  /// previous word's end). Snaps to the 10ms LRC grid and keeps at least
  /// 10ms between neighbouring starts; word 0 also retimes the line
  /// stamp (A2 convention via [setWord]).
  LyricsEditorModel setWordBoundary(
    int lineIndex,
    int wordIndex,
    Duration newStart,
  ) {
    final line = _lineAt(lineIndex);
    final starts = line?.wordStarts;
    if (line == null ||
        starts == null ||
        !line.hasCompleteWords ||
        wordIndex < 0 ||
        wordIndex >= starts.length) {
      return this;
    }

    final minMs = wordIndex == 0
        ? 0
        : starts[wordIndex - 1]!.inMilliseconds + _snapMs;
    final maxMs = wordIndex + 1 < starts.length
        ? starts[wordIndex + 1]!.inMilliseconds - _snapMs
        : lineEndFor(lineIndex).inMilliseconds - _snapMs;
    if (maxMs < minMs) return this;

    final snappedMs = _snapToGrid(newStart.inMilliseconds).clamp(minMs, maxMs);
    return setWord(
      lineIndex,
      wordIndex,
      Duration(milliseconds: snappedMs < 0 ? 0 : snappedMs),
    );
  }

  /// Drags the shared boundary at the end of the line: retimes the next
  /// stamped line, whose word starts shift by the same delta
  /// ([setLineTimestamp] keeps its rhythm). No-op when no following line
  /// has a stamp to move.
  LyricsEditorModel setLineEndBoundary(int lineIndex, Duration newEnd) {
    final line = _lineAt(lineIndex);
    final starts = line?.wordStarts;
    if (line == null || starts == null || !line.hasCompleteWords) {
      return this;
    }
    final nextIndex = _nextStampedIndex(lineIndex);
    if (nextIndex == null) return this;

    final minMs = starts.last!.inMilliseconds + _snapMs;
    var maxMs = 1 << 31;
    final afterIndex = _nextStampedIndex(nextIndex);
    if (afterIndex != null) {
      maxMs = lines[afterIndex].timestamp!.inMilliseconds - _snapMs;
    }
    if (maxMs < minMs) return this;

    final snappedMs = _snapToGrid(newEnd.inMilliseconds).clamp(minMs, maxMs);
    return setLineTimestamp(
      nextIndex,
      Duration(milliseconds: snappedMs < 0 ? 0 : snappedMs),
    );
  }

  /// Whether the line-end boundary can be dragged (complete words and a
  /// following stamped line to retime).
  bool isLineEndDraggable(int lineIndex) {
    final line = _lineAt(lineIndex);
    return line != null &&
        line.hasCompleteWords &&
        _nextStampedIndex(lineIndex) != null;
  }

  /// Seeds evenly spaced word starts across the line's window so the
  /// timeline has clips to drag. Only for stamped lines with no word
  /// data yet.
  LyricsEditorModel autoFillWords(int lineIndex) {
    final line = _lineAt(lineIndex);
    if (line == null) return this;
    final ts = line.timestamp;
    if (ts == null || line.hasAnyWords) return this;
    final tokens = line.tokens;
    if (tokens.isEmpty) return this;

    var spanMs = lineEndFor(lineIndex).inMilliseconds - ts.inMilliseconds;
    if (spanMs <= 0) spanMs = 2000;
    final stepMs = _snapToGrid(spanMs ~/ tokens.length);
    final step = stepMs < _snapMs ? _snapMs : stepMs;

    return _replace(
      lineIndex,
      line.copyWith(
        wordStarts: [
          for (var i = 0; i < tokens.length; i++)
            Duration(milliseconds: ts.inMilliseconds + step * i),
        ],
        clearSegmentBreaks: true,
      ),
    );
  }

  /// Toggles a syllable boundary inside [tokenIndex] at [charOffset] (a
  /// char position within the token core, 1..coreLen-1). Adding a break
  /// splits the covering segment in two, interpolating the new start
  /// proportionally within its window; removing one merges the adjacent
  /// segments and drops the inner start. Only for fully captured lines.
  LyricsEditorModel toggleSegmentBreak(
    int lineIndex,
    int tokenIndex,
    int charOffset,
  ) {
    final line = _lineAt(lineIndex);
    final starts = line?.wordStarts;
    if (line == null || starts == null || !line.hasCompleteWords) {
      return this;
    }
    final tokens = line.tokens;
    if (tokenIndex < 0 || tokenIndex >= tokens.length) return this;
    final coreLen = tokens[tokenIndex].trim().length;
    if (charOffset < 1 || charOffset > coreLen - 1) return this;

    final breaks = [
      for (final tokenBreaks in line.segmentBreaks ?? const <List<int>>[])
        List<int>.of(tokenBreaks),
    ];
    while (breaks.length < tokens.length) {
      breaks.add(<int>[]);
    }

    var flatFirst = 0;
    for (var t = 0; t < tokenIndex; t++) {
      flatFirst += 1 + breaks[t].length;
    }

    final existing = breaks[tokenIndex].indexOf(charOffset);
    if (existing >= 0) {
      breaks[tokenIndex].removeAt(existing);
      final updated = List<Duration?>.of(starts)
        ..removeAt(flatFirst + existing + 1);
      return _replace(
        lineIndex,
        line.copyWith(wordStarts: updated, segmentBreaks: breaks),
      );
    }

    var position = breaks[tokenIndex].indexWhere((b) => b > charOffset);
    if (position < 0) position = breaks[tokenIndex].length;
    breaks[tokenIndex].insert(position, charOffset);

    // Interpolate the new segment start inside the segment being split.
    final segCharStart = position == 0 ? 0 : breaks[tokenIndex][position - 1];
    final segCharEnd = position + 1 < breaks[tokenIndex].length
        ? breaks[tokenIndex][position + 1]
        : coreLen;
    final segFlat = flatFirst + position;
    final segStartMs = starts[segFlat]!.inMilliseconds;
    final nextStart = segFlat + 1 < starts.length ? starts[segFlat + 1] : null;
    final segEndMs = (nextStart ?? lineEndFor(lineIndex)).inMilliseconds;
    final charSpan = (segCharEnd - segCharStart).clamp(1, 1 << 31);
    final ratio = (charOffset - segCharStart) / charSpan;
    var newMs = _snapToGrid(
      segStartMs + (ratio * (segEndMs - segStartMs)).round(),
    );
    newMs = newMs.clamp(segStartMs + _snapMs, segEndMs - _snapMs);

    final updated = List<Duration?>.of(starts)
      ..insert(segFlat + 1, Duration(milliseconds: newMs));
    return _replace(
      lineIndex,
      line.copyWith(wordStarts: updated, segmentBreaks: breaks),
    );
  }

  /// Index of [editorIndex] inside the normalized (non-empty) line list, or
  /// -1 when the line has no text. Used to map editor selections onto
  /// preview data.
  int indexOfNormalizedLine(int editorIndex) {
    var normalized = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].text.trim().isNotEmpty) normalized++;
      if (i == editorIndex) return normalized;
    }
    return normalized;
  }

  /// Builds the final line list for saving: trims text, backfills missing
  /// line timestamps, keeps timestamps monotonic, drops partial word sets,
  /// and derives the line timestamp from the first word when words are
  /// complete (A2 convention).
  List<LyricsLine> normalizeForSave() {
    final sourceLines =
        <(String, Duration?, List<Duration?>?, List<List<int>>?)>[];
    for (final line in lines) {
      final trimmed = line.text.trim();
      if (trimmed.isEmpty) continue;
      sourceLines.add((
        trimmed,
        line.hasCompleteWords ? line.wordStarts!.first! : line.timestamp,
        _completeStartsOrNull(line, trimmed),
        line.segmentBreaks,
      ));
    }
    if (sourceLines.isEmpty) return const [];

    final filled = List<Duration?>.from(
      sourceLines.map((row) => row.$2),
    );
    final stampedIndices = <int>[
      for (var index = 0; index < sourceLines.length; index++)
        if (filled[index] != null) index,
    ];

    if (stampedIndices.isEmpty) {
      for (var index = 0; index < sourceLines.length; index++) {
        filled[index] = Duration(seconds: index * 2);
      }
    } else {
      const defaultStep = Duration(seconds: 2);
      final firstStampedIndex = stampedIndices.first;
      final firstStampedTime = filled[firstStampedIndex]!;
      for (var index = firstStampedIndex - 1; index >= 0; index--) {
        final backfilled =
            firstStampedTime -
            Duration(
              seconds: defaultStep.inSeconds * (firstStampedIndex - index),
            );
        filled[index] = backfilled.isNegative ? Duration.zero : backfilled;
      }

      for (
        var stampIndex = 0;
        stampIndex < stampedIndices.length - 1;
        stampIndex++
      ) {
        final startIndex = stampedIndices[stampIndex];
        final endIndex = stampedIndices[stampIndex + 1];
        final start = filled[startIndex]!;
        final end = filled[endIndex]!;
        final gapCount = endIndex - startIndex - 1;
        if (gapCount <= 0) continue;

        final deltaMs = end.inMilliseconds - start.inMilliseconds;
        final stepMs = deltaMs ~/ (gapCount + 1);
        for (var offset = 1; offset <= gapCount; offset++) {
          filled[startIndex + offset] = Duration(
            milliseconds: start.inMilliseconds + (stepMs * offset),
          );
        }
      }

      final lastStampedIndex = stampedIndices.last;
      for (var index = lastStampedIndex + 1; index < filled.length; index++) {
        final previous = filled[index - 1] ?? Duration.zero;
        filled[index] = previous + defaultStep;
      }
    }

    var lastMs = 0;
    final normalized = <LyricsLine>[];
    for (var index = 0; index < sourceLines.length; index++) {
      final (text, _, starts, segmentBreaks) = sourceLines[index];
      final timestamp = filled[index] ?? Duration(milliseconds: lastMs);
      final nextMs = timestamp.inMilliseconds < lastMs
          ? lastMs
          : timestamp.inMilliseconds;
      final bumpMs = nextMs - timestamp.inMilliseconds;
      lastMs = nextMs;

      List<LyricsWord>? words;
      if (starts != null) {
        final tokens = EditableLyricLine.tokenizeLineText(text);
        final layout = EditableLyricLine(
          text: text,
          timestamp: null,
          wordStarts: starts,
          segmentBreaks: segmentBreaks,
        ).segmentLayout;
        words = [];
        for (var flat = 0; flat < layout.length; flat++) {
          final entry = layout[flat];
          final token = tokens[entry.tokenIndex];
          final core = token.trim();
          final isTokenLast = flat + 1 >= layout.length ||
              layout[flat + 1].tokenIndex != entry.tokenIndex;
          final leading = entry.tokenIndex == 0 && flat == 0
              ? token.substring(0, token.length - token.trimLeft().length)
              : '';
          final trailing = isTokenLast
              ? token.substring(token.trimRight().length)
              : '';
          final start = Duration(
            milliseconds: starts[flat]!.inMilliseconds + bumpMs,
          );
          words.add(
            LyricsWord(
              start: start,
              end: start,
              text: leading +
                  core.substring(entry.charStart, entry.charEnd) +
                  trailing,
            ),
          );
        }
      }
      normalized.add(
        LyricsLine(
          timestamp: Duration(milliseconds: nextMs),
          text: text,
          words: words,
        ),
      );
    }
    return normalized;
  }

  /// Seeds word starts and segment breaks from parsed word tags. Segments
  /// are grouped onto tokens by trimmed-length concatenation, so syllable
  /// tags inside one token (e.g. `<00:10.00>Hel<00:10.40>lo`) map to
  /// segment breaks. Returns null when the segments cannot align.
  static (List<Duration?>, List<List<int>>)? _seedWordData(LyricsLine line) {
    final words = line.words;
    if (words == null || words.isEmpty) return null;
    final tokens = EditableLyricLine.tokenizeLineText(line.text);
    if (tokens.isEmpty) return null;

    final segments = <LyricsWord>[
      for (final word in words) ...LyricsService.splitKaraokeWord(word),
    ];

    final starts = <Duration?>[];
    final breaks = <List<int>>[];
    var segIndex = 0;
    for (final token in tokens) {
      final coreLen = token.trim().length;
      if (coreLen <= 0) return null;
      var consumed = 0;
      final tokenBreaks = <int>[];
      while (consumed < coreLen) {
        if (segIndex >= segments.length) return null;
        final length = segments[segIndex].text.trim().length;
        if (length <= 0) return null;
        consumed += length;
        if (consumed > coreLen) return null;
        starts.add(segments[segIndex].start);
        if (consumed < coreLen) tokenBreaks.add(consumed);
        segIndex++;
      }
      breaks.add(tokenBreaks);
    }
    if (segIndex != segments.length) return null;
    return (starts, breaks);
  }

  /// Carries word data across a text edit: starts and breaks survive only
  /// when the edited row keeps the same token count and every break still
  /// falls inside its token's core.
  static (List<Duration?>?, List<List<int>>?) _remapWordData(
    EditableLyricLine old,
    String newText,
  ) {
    final starts = old.wordStarts;
    if (starts == null) return (null, null);
    final newTokens = EditableLyricLine.tokenizeLineText(newText);
    if (newTokens.length != old.tokens.length) return (null, null);

    final breaks = old.segmentBreaks;
    if (breaks != null) {
      if (breaks.length != newTokens.length) return (null, null);
      for (var t = 0; t < breaks.length; t++) {
        final coreLen = newTokens[t].trim().length;
        for (final offset in breaks[t]) {
          if (offset < 1 || offset > coreLen - 1) return (null, null);
        }
      }
    }
    return (starts, breaks);
  }

  static List<Duration?>? _completeStartsOrNull(
    EditableLyricLine line,
    String trimmedText,
  ) {
    final starts = line.wordStarts;
    if (starts == null) return null;
    final trimmed = EditableLyricLine(
      text: trimmedText,
      timestamp: null,
      wordStarts: starts,
      segmentBreaks: line.segmentBreaks,
    );
    if (starts.length != trimmed.segmentCount) return null;
    if (starts.any((start) => start == null)) return null;
    return starts;
  }

  EditableLyricLine? _lineAt(int index) {
    if (index < 0 || index >= lines.length) return null;
    return lines[index];
  }

  int? _nextStampedIndex(int lineIndex) {
    for (var i = lineIndex + 1; i < lines.length; i++) {
      final row = lines[i];
      if (row.text.trim().isEmpty) continue;
      final ts = row.timestamp;
      if (ts != null) return i;
    }
    return null;
  }

  static Duration? _lastCapturedStart(EditableLyricLine line) {
    final starts = line.wordStarts;
    if (starts == null) return null;
    Duration? last;
    for (final start in starts) {
      if (start != null) last = start;
    }
    return last;
  }

  static const int _snapMs = 10;

  static int _snapToGrid(int milliseconds) => (milliseconds ~/ 10) * 10;

  LyricsEditorModel _replace(int index, EditableLyricLine line) {
    return LyricsEditorModel([
      for (var i = 0; i < lines.length; i++) i == index ? line : lines[i],
    ]);
  }

  static Duration _shiftClamped(Duration time, Duration delta) {
    return Duration(
      milliseconds: (time.inMilliseconds + delta.inMilliseconds).clamp(
        0,
        1 << 31,
      ),
    );
  }
}
