import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/player_service.dart';

void main() {
  group('canonicalPlaybackFileType', () {
    test('prefers the real file extension over stale stored file type', () {
      expect(
        canonicalPlaybackFileType(
          fileType: 'M4A',
          filePath: '/music/library/example.ogg',
        ),
        'ogg',
      );
    });

    test('normalizes mime-style and ogg-family values', () {
      expect(
        canonicalPlaybackFileType(fileType: 'audio/ogg', filePath: null),
        'ogg',
      );
      expect(
        canonicalPlaybackFileType(fileType: 'audio/mp4', filePath: null),
        'm4a',
      );
      expect(
        canonicalPlaybackFileType(fileType: 'OpUs', filePath: null),
        'opus',
      );
      expect(
        canonicalPlaybackFileType(fileType: '.oga', filePath: null),
        'ogg',
      );
    });
  });

  group('shouldOptimisticallySyncSkipForLoopMode', () {
    test('disables optimistic UI skip sync for repeat-one only', () {
      expect(shouldOptimisticallySyncSkipForLoopMode(LoopMode.off), isTrue);
      expect(shouldOptimisticallySyncSkipForLoopMode(LoopMode.all), isTrue);
      expect(shouldOptimisticallySyncSkipForLoopMode(LoopMode.one), isFalse);
    });
  });
}
