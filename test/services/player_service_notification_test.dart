import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/player_service.dart';

void main() {
  group('shouldSyncNotificationForRepeatOneLoop', () {
    test('returns true when repeat-one wraps from the end to the start', () {
      expect(
        shouldSyncNotificationForRepeatOneLoop(
          loopMode: LoopMode.one,
          sameTrack: true,
          previousPosition: const Duration(minutes: 2, seconds: 58),
          currentPosition: const Duration(milliseconds: 120),
          trackDuration: const Duration(minutes: 3),
        ),
        isTrue,
      );
    });

    test('returns false for normal progress updates on the same track', () {
      expect(
        shouldSyncNotificationForRepeatOneLoop(
          loopMode: LoopMode.one,
          sameTrack: true,
          previousPosition: const Duration(minutes: 1),
          currentPosition: const Duration(minutes: 1, seconds: 2),
          trackDuration: const Duration(minutes: 3),
        ),
        isFalse,
      );
    });

    test('returns false when repeat-one is not active', () {
      expect(
        shouldSyncNotificationForRepeatOneLoop(
          loopMode: LoopMode.all,
          sameTrack: true,
          previousPosition: const Duration(minutes: 2, seconds: 58),
          currentPosition: const Duration(milliseconds: 120),
          trackDuration: const Duration(minutes: 3),
        ),
        isFalse,
      );
    });
  });
}
