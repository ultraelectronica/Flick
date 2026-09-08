import 'package:flick/features/player/widgets/lyrics_editor_model.dart';
import 'package:flick/services/lyrics_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final service = LyricsService();

  group('LyricsEditorModel round-trip', () {
    test('enhanced LRC word timings survive seed, normalize, and rebuild', () {
      final raw =
          '[00:10.00]<00:10.00>Hello <00:10.50>wide <00:11.00>world\n'
          '[00:14.00]<00:14.00>Second <00:15.00>line\n';
      final model = LyricsEditorModel.fromLyrics(
        service.parseLyricsText(raw),
      );

      final normalized = model.normalizeForSave();
      expect(normalized, hasLength(2));

      final rebuilt = service.buildLrcContent(lines: normalized);
      final reparsed = service.parseLyricsText(rebuilt);

      final first = reparsed.lines.first;
      expect(first.words, isNotNull);
      expect(first.words!.map((w) => w.start), [
        const Duration(seconds: 10),
        const Duration(milliseconds: 10500),
        const Duration(seconds: 11),
      ]);
      // A2 convention: line timestamp equals the first word start.
      expect(first.timestamp, first.words!.first.start);

      final second = reparsed.lines[1];
      expect(second.words, isNotNull);
      expect(second.words!.map((w) => w.start), [
        const Duration(seconds: 14),
        const Duration(seconds: 15),
      ]);
    });

    test('seeding drops word data when token counts mismatch', () {
      const data = LyricsData(
        lines: [
          LyricsLine(
            timestamp: Duration(seconds: 5),
            text: 'one two three four',
            words: [
              LyricsWord(
                start: Duration(seconds: 5),
                end: Duration(seconds: 6),
                text: 'one two',
              ),
              LyricsWord(
                start: Duration(seconds: 6),
                end: Duration(seconds: 7),
                text: 'three',
              ),
            ],
          ),
        ],
        isSynchronized: true,
        rawContent: '',
      );

      final model = LyricsEditorModel.fromLyrics(data);
      // Three segments cannot align to four tokens.
      expect(model.lines.single.wordStarts, isNull);
      expect(model.lines.single.timestamp, const Duration(seconds: 5));
    });

    test('a single multi-token word seeds proportionally split slots', () {
      const data = LyricsData(
        lines: [
          LyricsLine(
            timestamp: Duration(seconds: 5),
            text: 'one two three',
            words: [
              LyricsWord(
                start: Duration(seconds: 5),
                end: Duration(seconds: 8),
                text: 'one two three',
              ),
            ],
          ),
        ],
        isSynchronized: true,
        rawContent: '',
      );

      final model = LyricsEditorModel.fromLyrics(data);
      expect(model.lines.single.wordStarts, hasLength(3));
      expect(model.lines.single.capturedWordCount, 3);
      expect(model.lines.single.wordStarts!.first, const Duration(seconds: 5));
      expect(model.lines.single.hasCompleteWords, isTrue);
    });
  });

  group('normalizeForSave word rules', () {
    test('partial word sets are dropped but the line stamp survives', () {
      const model = LyricsEditorModel([
        EditableLyricLine(
          text: 'alpha beta gamma',
          timestamp: Duration(seconds: 10),
          wordStarts: [
            Duration(seconds: 10),
            Duration(seconds: 11),
            null,
          ],
        ),
      ]);

      final normalized = model.normalizeForSave();
      expect(normalized.single.words, isNull);
      expect(normalized.single.timestamp, const Duration(seconds: 10));
    });

    test('complete word sets override the line timestamp with word zero', () {
      const model = LyricsEditorModel([
        EditableLyricLine(
          text: 'alpha beta',
          timestamp: Duration(seconds: 30),
          wordStarts: [Duration(seconds: 10), Duration(seconds: 12)],
        ),
      ]);

      final normalized = model.normalizeForSave();
      expect(normalized.single.timestamp, const Duration(seconds: 10));
      expect(normalized.single.words!.map((w) => w.start), [
        const Duration(seconds: 10),
        const Duration(seconds: 12),
      ]);
    });

    test('monotonic bumps shift word starts along with the line', () {
      const model = LyricsEditorModel([
        EditableLyricLine(
          text: 'first line',
          timestamp: Duration(seconds: 10),
          wordStarts: [Duration(seconds: 10), Duration(seconds: 11)],
        ),
        EditableLyricLine(
          text: 'second line',
          timestamp: Duration(seconds: 9),
          wordStarts: [Duration(seconds: 9), Duration(seconds: 11)],
        ),
      ]);

      final normalized = model.normalizeForSave();
      expect(normalized[1].timestamp, const Duration(seconds: 10));
      expect(normalized[1].words!.map((w) => w.start), [
        const Duration(seconds: 10),
        const Duration(seconds: 12),
      ]);
    });
  });

  group('reflowText', () {
    test('keeps word starts when the token count is unchanged', () {
      const model = LyricsEditorModel([
        EditableLyricLine(
          text: 'alpha beta',
          timestamp: Duration(seconds: 3),
          wordStarts: [Duration(seconds: 3), Duration(seconds: 4)],
        ),
      ]);

      final reflowed = model.reflowText('alpha beta\n');
      expect(reflowed.lines.single.wordStarts, [
        const Duration(seconds: 3),
        const Duration(seconds: 4),
      ]);
      expect(reflowed.lines.single.timestamp, const Duration(seconds: 3));
    });

    test('drops word starts when the token count changes', () {
      const model = LyricsEditorModel([
        EditableLyricLine(
          text: 'alpha beta',
          timestamp: Duration(seconds: 3),
          wordStarts: [Duration(seconds: 3), Duration(seconds: 4)],
        ),
      ]);

      final reflowed = model.reflowText('alpha beta gamma\n');
      expect(reflowed.lines.single.wordStarts, isNull);
      expect(reflowed.lines.single.timestamp, const Duration(seconds: 3));
    });
  });

  group('timestamp edits with word data', () {
    test('re-stamping shifts word starts by the delta', () {
      const model = LyricsEditorModel([
        EditableLyricLine(
          text: 'alpha beta',
          timestamp: Duration(seconds: 10),
          wordStarts: [Duration(seconds: 10), Duration(seconds: 12)],
        ),
      ]);

      final shifted = model.setLineTimestamp(
        0,
        const Duration(seconds: 13),
      );
      expect(shifted.lines.single.timestamp, const Duration(seconds: 13));
      expect(shifted.lines.single.wordStarts, [
        const Duration(seconds: 13),
        const Duration(seconds: 15),
      ]);
    });

    test('clearing the stamp drops the word data', () {
      const model = LyricsEditorModel([
        EditableLyricLine(
          text: 'alpha beta',
          timestamp: Duration(seconds: 10),
          wordStarts: [Duration(seconds: 10), Duration(seconds: 12)],
        ),
      ]);

      final cleared = model.setLineTimestamp(0, null);
      expect(cleared.lines.single.timestamp, isNull);
      expect(cleared.lines.single.wordStarts, isNull);
    });

    test('shiftAll moves stamps and word starts, clamped at zero', () {
      const model = LyricsEditorModel([
        EditableLyricLine(
          text: 'alpha beta',
          timestamp: Duration(milliseconds: 100),
          wordStarts: [
            Duration(milliseconds: 100),
            Duration(milliseconds: 9000),
          ],
        ),
      ]);

      final shifted = model.shiftAll(const Duration(milliseconds: -600));
      expect(shifted.lines.single.timestamp, Duration.zero);
      expect(shifted.lines.single.wordStarts, [
        Duration.zero,
        const Duration(milliseconds: 8400),
      ]);
    });
  });

  group('word stamping', () {
    const model = LyricsEditorModel([
      EditableLyricLine(text: 'alpha beta', timestamp: null),
    ]);

    test('stampNextWord fills slots in order and stamps the line first', () {
      var current = model;
      final (afterFirst, firstIndex) = current.stampNextWord(
        0,
        const Duration(seconds: 10),
      );
      current = afterFirst;

      expect(firstIndex, 0);
      expect(current.lines.single.timestamp, const Duration(seconds: 10));
      expect(current.lines.single.capturedWordCount, 1);

      final (afterSecond, secondIndex) = current.stampNextWord(
        0,
        const Duration(seconds: 11),
      );
      expect(secondIndex, 1);
      expect(afterSecond.lines.single.hasCompleteWords, isTrue);

      final (unchanged, none) = afterSecond.stampNextWord(
        0,
        const Duration(seconds: 20),
      );
      expect(none, isNull);
      expect(identical(unchanged, afterSecond), isTrue);
    });

    test('undoLastWordStamp removes the newest capture', () {
      final stamped = model
          .stampNextWord(0, const Duration(seconds: 10))
          .$1
          .stampNextWord(0, const Duration(seconds: 11))
          .$1;

      final undone = stamped.undoLastWordStamp(0);
      expect(undone.lines.single.wordStarts, [
        const Duration(seconds: 10),
        null,
      ]);

      final cleared = undone.clearWord(0, 0).clearWords(0);
      expect(cleared.lines.single.wordStarts, isNull);
      // Clearing words keeps the line stamp usable on its own.
      expect(cleared.lines.single.timestamp, const Duration(seconds: 10));
    });

    test('setWord on the first slot syncs the line timestamp', () {
      final stamped = model
          .stampNextWord(0, const Duration(seconds: 10))
          .$1
          .stampNextWord(0, const Duration(seconds: 11))
          .$1;

      final moved = stamped.setWord(
        0,
        0,
        const Duration(milliseconds: 9800),
      );
      expect(moved.lines.single.timestamp, const Duration(milliseconds: 9800));
      expect(moved.lines.single.wordStarts!.first, moved.lines.single.timestamp);

      final nudged = moved.nudgeWord(0, 1, const Duration(milliseconds: 100));
      expect(
        nudged.lines.single.wordStarts![1],
        const Duration(milliseconds: 11100),
      );
    });
  });

  group('line index mapping', () {
    test('indexOfNormalizedLine skips empty rows', () {
      const model = LyricsEditorModel([
        EditableLyricLine(text: 'one', timestamp: Duration(seconds: 1)),
        EditableLyricLine(text: '', timestamp: null),
        EditableLyricLine(text: 'two', timestamp: Duration(seconds: 2)),
      ]);

      expect(model.indexOfNormalizedLine(0), 0);
      expect(model.indexOfNormalizedLine(1), 0);
      expect(model.indexOfNormalizedLine(2), 1);
    });
  });

  group('timeline windows', () {
    const model = LyricsEditorModel([
      EditableLyricLine(
        text: 'one two three',
        timestamp: Duration(seconds: 10),
        wordStarts: [
          Duration(seconds: 10),
          Duration(milliseconds: 10400),
          Duration(milliseconds: 10800),
        ],
      ),
      EditableLyricLine(
        text: 'next line',
        timestamp: Duration(seconds: 12),
        wordStarts: [Duration(seconds: 12), Duration(milliseconds: 12300)],
      ),
      EditableLyricLine(text: 'unstamped row', timestamp: null),
    ]);

    test('wordWindows chains ends to next starts, last runs to line end', () {
      final windows = model.wordWindows(0)!;
      expect(windows, hasLength(3));
      expect(windows[0], (
        start: const Duration(seconds: 10),
        end: const Duration(milliseconds: 10400),
      ));
      expect(windows[2].end, const Duration(seconds: 12));
    });

    test('wordWindows is null for partial or missing word data', () {
      const partial = LyricsEditorModel([
        EditableLyricLine(
          text: 'alpha beta',
          timestamp: Duration(seconds: 3),
          wordStarts: [Duration(seconds: 3), null],
        ),
      ]);
      expect(partial.wordWindows(0), isNull);
      expect(model.wordWindows(2), isNull);
    });

    test('lineEndFor falls back to last start plus 5s without a next stamp', () {
      expect(model.lineEndFor(0), const Duration(seconds: 12));
      expect(model.lineEndFor(1), const Duration(milliseconds: 17300));
    });

    test('isLineEndDraggable requires a following stamped line', () {
      expect(model.isLineEndDraggable(0), isTrue);
      expect(model.isLineEndDraggable(1), isFalse);
      expect(model.isLineEndDraggable(2), isFalse);
    });
  });

  group('setWordBoundary', () {
    const model = LyricsEditorModel([
      EditableLyricLine(
        text: 'one two three',
        timestamp: Duration(seconds: 10),
        wordStarts: [
          Duration(seconds: 10),
          Duration(milliseconds: 10400),
          Duration(milliseconds: 10800),
        ],
      ),
      EditableLyricLine(
        text: 'next line',
        timestamp: Duration(seconds: 12),
        wordStarts: [Duration(seconds: 12), Duration(milliseconds: 12300)],
      ),
    ]);

    test('snaps to the 10ms grid and accepts in-range moves', () {
      final moved = model.setWordBoundary(
        0,
        1,
        const Duration(milliseconds: 10417),
      );
      expect(
        moved.lines[0].wordStarts![1],
        const Duration(milliseconds: 10410),
      );
    });

    test('clamps between neighbouring starts with a 10ms gap', () {
      final low = model.setWordBoundary(0, 1, const Duration(seconds: 9));
      expect(
        low.lines[0].wordStarts![1],
        const Duration(milliseconds: 10010),
      );

      final high = model.setWordBoundary(0, 1, const Duration(seconds: 12));
      expect(
        high.lines[0].wordStarts![1],
        const Duration(milliseconds: 10790),
      );
    });

    test('word zero retimes the line stamp with it', () {
      final moved = model.setWordBoundary(
        0,
        0,
        const Duration(milliseconds: 9500),
      );
      expect(moved.lines[0].timestamp, const Duration(milliseconds: 9500));
      expect(moved.lines[0].wordStarts!.first, moved.lines[0].timestamp);
    });

    test('the last word cannot start past the line end', () {
      final moved = model.setWordBoundary(0, 2, const Duration(seconds: 13));
      expect(
        moved.lines[0].wordStarts![2],
        const Duration(milliseconds: 11990),
      );
    });
  });

  group('setLineEndBoundary', () {
    const model = LyricsEditorModel([
      EditableLyricLine(
        text: 'one two three',
        timestamp: Duration(seconds: 10),
        wordStarts: [
          Duration(seconds: 10),
          Duration(milliseconds: 10400),
          Duration(milliseconds: 10800),
        ],
      ),
      EditableLyricLine(
        text: 'next line',
        timestamp: Duration(seconds: 12),
        wordStarts: [Duration(seconds: 12), Duration(milliseconds: 12300)],
      ),
      EditableLyricLine(text: 'unstamped row', timestamp: null),
    ]);

    test('retimes the next stamped line and shifts its words with it', () {
      final moved = model.setLineEndBoundary(0, const Duration(seconds: 13));
      expect(moved.lines[1].timestamp, const Duration(seconds: 13));
      expect(moved.lines[1].wordStarts, [
        const Duration(seconds: 13),
        const Duration(milliseconds: 13300),
      ]);
      expect(identical(moved.lines[0], model.lines[0]), isTrue);
    });

    test('clamps so the last word keeps at least 10ms', () {
      final moved = model.setLineEndBoundary(0, const Duration(seconds: 10));
      expect(moved.lines[1].timestamp, const Duration(milliseconds: 10810));
    });

    test('is a no-op without a following stamped line', () {
      final moved = model.setLineEndBoundary(1, const Duration(seconds: 30));
      expect(identical(moved, model), isTrue);
    });
  });

  group('autoFillWords', () {
    test('distributes even 10ms-snapped starts across the line window', () {
      const model = LyricsEditorModel([
        EditableLyricLine(
          text: 'one two three',
          timestamp: Duration(seconds: 10),
        ),
        EditableLyricLine(
          text: 'next',
          timestamp: Duration(seconds: 14),
        ),
      ]);

      final filled = model.autoFillWords(0);
      expect(filled.lines[0].wordStarts, [
        const Duration(seconds: 10),
        const Duration(milliseconds: 11330),
        const Duration(milliseconds: 12660),
      ]);
      expect(filled.lines[0].hasCompleteWords, isTrue);
    });

    test('falls back to a 5s window when nothing follows', () {
      const model = LyricsEditorModel([
        EditableLyricLine(text: 'one two', timestamp: Duration(seconds: 5)),
      ]);

      expect(model.autoFillWords(0).lines.single.wordStarts, [
        const Duration(seconds: 5),
        const Duration(milliseconds: 7500),
      ]);
    });

    test('skips unstamped lines and lines that already have words', () {
      const unstamped = LyricsEditorModel([
        EditableLyricLine(text: 'one two', timestamp: null),
      ]);
      expect(identical(unstamped.autoFillWords(0), unstamped), isTrue);

      const stamped = LyricsEditorModel([
        EditableLyricLine(
          text: 'one two',
          timestamp: Duration(seconds: 5),
          wordStarts: [Duration(seconds: 5), Duration(seconds: 6)],
        ),
      ]);
      expect(identical(stamped.autoFillWords(0), stamped), isTrue);
    });
  });

  group('timeline edits survive the enhanced LRC round-trip', () {
    test('boundary drag and line-end drag rebuild exactly', () {
      final raw =
          '[00:10.00]<00:10.00>Hello <00:10.50>wide <00:11.00>world\n'
          '[00:14.00]<00:14.00>Second <00:15.00>line\n';
      final edited = LyricsEditorModel.fromLyrics(
        service.parseLyricsText(raw),
      )
          .setWordBoundary(0, 1, const Duration(milliseconds: 10730))
          .setLineEndBoundary(0, const Duration(seconds: 13));

      final rebuilt = service.buildLrcContent(
        lines: edited.normalizeForSave(),
      );
      final reparsed = service.parseLyricsText(rebuilt);

      expect(reparsed.lines.first.words!.map((w) => w.start), [
        const Duration(seconds: 10),
        const Duration(milliseconds: 10730),
        const Duration(seconds: 11),
      ]);
      expect(reparsed.lines[1].timestamp, const Duration(seconds: 13));
      expect(reparsed.lines[1].words!.map((w) => w.start), [
        const Duration(seconds: 13),
        const Duration(seconds: 14),
      ]);
    });
  });

  group('syllable segments', () {
    test('syllable tags inside a token seed with segment breaks', () {
      final raw =
          '[00:10.00]<00:10.00>Hel<00:10.40>lo <00:11.00>world\n';
      final model = LyricsEditorModel.fromLyrics(
        service.parseLyricsText(raw),
      );

      final line = model.lines.single;
      expect(line.tokenCount, 2);
      expect(line.segmentCount, 3);
      expect(line.wordStarts, [
        const Duration(seconds: 10),
        const Duration(milliseconds: 10400),
        const Duration(seconds: 11),
      ]);
      expect(line.segmentBreaks, [
        [3],
        [],
      ]);
      expect(line.hasCompleteWords, isTrue);
      expect(line.segmentLabel(0), 'Hel');
      expect(line.segmentLabel(1), 'lo');
      expect(line.segmentLabel(2), 'world');
    });

    test('syllable timings survive the enhanced LRC round-trip', () {
      final raw =
          '[00:10.00]<00:10.00>Hel<00:10.40>lo <00:11.00>world\n';
      final model = LyricsEditorModel.fromLyrics(
        service.parseLyricsText(raw),
      );

      final rebuilt = service.buildLrcContent(
        lines: model.normalizeForSave(),
      );
      final reparsed = service.parseLyricsText(rebuilt);

      final line = reparsed.lines.single;
      expect(line.words!.map((w) => w.text), ['Hel', 'lo ', 'world']);
      expect(line.words!.map((w) => w.start), [
        const Duration(seconds: 10),
        const Duration(milliseconds: 10400),
        const Duration(seconds: 11),
      ]);
      // Seeding the reparsed data yields the same segmentation.
      final round = LyricsEditorModel.fromLyrics(reparsed);
      expect(round.lines.single.segmentBreaks, [
        [3],
        [],
      ]);
    });

    test('toggleSegmentBreak splits proportionally and merges back', () {
      const model = LyricsEditorModel([
        EditableLyricLine(
          text: 'Hello world',
          timestamp: Duration(seconds: 10),
          wordStarts: [Duration(seconds: 10), Duration(seconds: 11)],
        ),
        EditableLyricLine(
          text: 'next',
          timestamp: Duration(seconds: 12),
        ),
      ]);

      final split = model.toggleSegmentBreak(0, 0, 3);
      final line = split.lines[0];
      expect(line.segmentCount, 3);
      expect(line.wordStarts, [
        const Duration(seconds: 10),
        const Duration(milliseconds: 10600),
        const Duration(seconds: 11),
      ]);
      expect(line.segmentBreaks, [
        [3],
        [],
      ]);

      final merged = split.toggleSegmentBreak(0, 0, 3);
      expect(merged.lines[0].segmentCount, 2);
      expect(merged.lines[0].wordStarts, [
        const Duration(seconds: 10),
        const Duration(seconds: 11),
      ]);
      expect(merged.lines[0].segmentBreaks, [
        [],
        [],
      ]);
    });

    test('setWordBoundary clamps between intra-token neighbours', () {
      const model = LyricsEditorModel([
        EditableLyricLine(
          text: 'Hello world',
          timestamp: Duration(seconds: 10),
          wordStarts: [
            Duration(seconds: 10),
            Duration(milliseconds: 10600),
            Duration(seconds: 11),
          ],
          segmentBreaks: [
            [3],
            [],
          ],
        ),
      ]);

      final low = model.setWordBoundary(0, 1, const Duration(seconds: 9));
      expect(
        low.lines.single.wordStarts![1],
        const Duration(milliseconds: 10010),
      );

      final high = model.setWordBoundary(0, 1, const Duration(seconds: 12));
      expect(
        high.lines.single.wordStarts![1],
        const Duration(milliseconds: 10990),
      );
    });

    test('stamping fills segment slots across broken tokens', () {
      const seeded = LyricsEditorModel([
        EditableLyricLine(
          text: 'Hello world',
          timestamp: null,
          segmentBreaks: [
            [3],
            [],
          ],
        ),
      ]);

      final stamped = seeded
          .stampNextWord(0, const Duration(seconds: 10))
          .$1
          .stampNextWord(0, const Duration(milliseconds: 10400))
          .$1
          .stampNextWord(0, const Duration(seconds: 11))
          .$1;

      final line = stamped.lines.single;
      expect(line.hasCompleteWords, isTrue);
      expect(line.timestamp, const Duration(seconds: 10));
    });

    test('reflow keeps breaks when tokens still fit, drops otherwise', () {
      const model = LyricsEditorModel([
        EditableLyricLine(
          text: 'Hello world',
          timestamp: Duration(seconds: 10),
          wordStarts: [
            Duration(seconds: 10),
            Duration(milliseconds: 10600),
            Duration(seconds: 11),
          ],
          segmentBreaks: [
            [3],
            [],
          ],
        ),
      ]);

      final kept = model.reflowText('Hello there\n');
      expect(kept.lines.single.segmentBreaks, [
        [3],
        [],
      ]);
      expect(kept.lines.single.wordStarts, hasLength(3));

      final dropped = model.reflowText('Hi world\n');
      expect(dropped.lines.single.wordStarts, isNull);
      expect(dropped.lines.single.segmentBreaks, isNull);
      expect(dropped.lines.single.timestamp, const Duration(seconds: 10));
    });

    test('clearWords drops starts and breaks but keeps the stamp', () {
      const model = LyricsEditorModel([
        EditableLyricLine(
          text: 'Hello world',
          timestamp: Duration(seconds: 10),
          wordStarts: [
            Duration(seconds: 10),
            Duration(milliseconds: 10600),
            Duration(seconds: 11),
          ],
          segmentBreaks: [
            [3],
            [],
          ],
        ),
      ]);

      final cleared = model.clearWords(0);
      expect(cleared.lines.single.wordStarts, isNull);
      expect(cleared.lines.single.segmentBreaks, isNull);
      expect(cleared.lines.single.timestamp, const Duration(seconds: 10));
    });
  });
}
