import 'package:flick/services/lyrics_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('splitKaraokeWord', () {
    test('whole-line word splits into sequential token windows', () {
      const word = LyricsWord(
        start: Duration(seconds: 10),
        end: Duration(seconds: 14),
        text: 'Hello wide world',
      );
      final segments = LyricsService.splitKaraokeWord(word);

      expect(segments, hasLength(3));
      expect(segments.first.text, 'Hello ');
      expect(segments.last.text, 'world');
      expect(segments.first.start, const Duration(seconds: 10));
      expect(segments.last.end, const Duration(seconds: 14));
      for (var i = 0; i + 1 < segments.length; i++) {
        expect(segments[i].end, segments[i + 1].start);
        expect(segments[i].start, lessThanOrEqualTo(segments[i + 1].start));
      }
    });

    test('keeps leading whitespace attached to the first segment', () {
      const word = LyricsWord(
        start: Duration(seconds: 0),
        end: Duration(seconds: 2),
        text: '  alpha beta',
      );
      final segments = LyricsService.splitKaraokeWord(word);

      expect(segments, hasLength(2));
      expect(segments.first.text, '  alpha ');
    });

    test('single-token word is returned unchanged', () {
      const word = LyricsWord(
        start: Duration(seconds: 1),
        end: Duration(seconds: 2),
        text: 'hello ',
      );

      expect(LyricsService.splitKaraokeWord(word), const [word]);
    });

    test('zero-width window shares parent timing across segments', () {
      const word = LyricsWord(
        start: Duration(seconds: 5),
        end: Duration(seconds: 5),
        text: 'a b c',
      );
      final segments = LyricsService.splitKaraokeWord(word);

      expect(segments, hasLength(3));
      for (final segment in segments) {
        expect(segment.start, const Duration(seconds: 5));
        expect(segment.end, const Duration(seconds: 5));
      }
    });

    test('whitespace-only word stays a single segment', () {
      const word = LyricsWord(
        start: Duration(seconds: 1),
        end: Duration(seconds: 2),
        text: ' ',
      );
      final segments = LyricsService.splitKaraokeWord(word);

      expect(segments, hasLength(1));
      expect(segments.single.text, ' ');
    });
  });
}
