import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/android_audio_engine.dart';

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

  group('shouldHandleManualCompletion', () {
    test('keeps manual completion handling for the Rust backend', () {
      expect(
        shouldHandleManualCompletion(
          usingRustBackend: true,
          loopMode: LoopMode.off,
        ),
        isTrue,
      );
      expect(
        shouldHandleManualCompletion(
          usingRustBackend: true,
          loopMode: LoopMode.one,
        ),
        isTrue,
      );
      expect(
        shouldHandleManualCompletion(
          usingRustBackend: true,
          loopMode: LoopMode.all,
        ),
        isTrue,
      );
    });

    test('lets just_audio own repeat-one and repeat-all completion', () {
      expect(
        shouldHandleManualCompletion(
          usingRustBackend: false,
          loopMode: LoopMode.off,
        ),
        isTrue,
      );
      expect(
        shouldHandleManualCompletion(
          usingRustBackend: false,
          loopMode: LoopMode.one,
        ),
        isFalse,
      );
      expect(
        shouldHandleManualCompletion(
          usingRustBackend: false,
          loopMode: LoopMode.all,
        ),
        isFalse,
      );
    });
  });

  group('shouldUseFastStartCurrentTrackOnly', () {
    test('disables fast-start when repeat-all is active', () {
      expect(
        shouldUseFastStartCurrentTrackOnly(
          allowFastStart: false,
          loadedSingleTrackOnly: false,
          sequenceIsEmpty: true,
          playlistLength: 100,
        ),
        isFalse,
      );
    });

    test('allows fast-start only for large eligible playlists', () {
      expect(
        shouldUseFastStartCurrentTrackOnly(
          allowFastStart: true,
          loadedSingleTrackOnly: false,
          sequenceIsEmpty: true,
          playlistLength: 25,
        ),
        isTrue,
      );

      expect(
        shouldUseFastStartCurrentTrackOnly(
          allowFastStart: true,
          loadedSingleTrackOnly: false,
          sequenceIsEmpty: true,
          playlistLength: 24,
        ),
        isFalse,
      );
    });
  });

  group('shouldExitSingleTrackMode', () {
    test('exits single-track mode once a real playlist is loaded', () {
      expect(
        shouldExitSingleTrackMode(
          loadedSingleTrackOnly: true,
          playerSequenceLength: 2,
        ),
        isTrue,
      );
    });

    test('stays in single-track mode for empty or single-item sequences', () {
      expect(
        shouldExitSingleTrackMode(
          loadedSingleTrackOnly: true,
          playerSequenceLength: 0,
        ),
        isFalse,
      );
      expect(
        shouldExitSingleTrackMode(
          loadedSingleTrackOnly: true,
          playerSequenceLength: 1,
        ),
        isFalse,
      );
      expect(
        shouldExitSingleTrackMode(
          loadedSingleTrackOnly: false,
          playerSequenceLength: 3,
        ),
        isFalse,
      );
    });
  });
}
