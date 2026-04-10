import 'package:flick/services/replay_play_tracker.dart';
import 'package:test/test.dart';

void main() {
  group('ReplayPlayTracker', () {
    test('counts a play only after 30 seconds of playback progress', () {
      final tracker = ReplayPlayTracker();
      tracker.startTrack('song-1');

      for (var second = 1; second < 30; second++) {
        expect(
          tracker.onPositionChanged(
            songId: 'song-1',
            position: Duration(seconds: second),
          ),
          isFalse,
        );
      }

      expect(
        tracker.onPositionChanged(
          songId: 'song-1',
          position: const Duration(seconds: 30),
        ),
        isTrue,
      );
      expect(
        tracker.onPositionChanged(
          songId: 'song-1',
          position: const Duration(seconds: 31),
        ),
        isFalse,
      );
    });

    test('ignores large seek jumps when measuring playback progress', () {
      final tracker = ReplayPlayTracker();
      tracker.startTrack('song-1');

      for (var second = 1; second <= 10; second++) {
        expect(
          tracker.onPositionChanged(
            songId: 'song-1',
            position: Duration(seconds: second),
          ),
          isFalse,
        );
      }

      expect(
        tracker.onPositionChanged(
          songId: 'song-1',
          position: const Duration(seconds: 40),
        ),
        isFalse,
      );

      for (var second = 41; second < 60; second++) {
        expect(
          tracker.onPositionChanged(
            songId: 'song-1',
            position: Duration(seconds: second),
          ),
          isFalse,
        );
      }

      expect(
        tracker.onPositionChanged(
          songId: 'song-1',
          position: const Duration(seconds: 60),
        ),
        isTrue,
      );
    });

    test(
      'counts coarse position updates when wall time matches progression',
      () {
        var now = DateTime(2026, 1, 1, 0, 0, 0);
        final tracker = ReplayPlayTracker(now: () => now);
        tracker.startTrack('song-1');

        now = now.add(const Duration(seconds: 8));
        expect(
          tracker.onPositionChanged(
            songId: 'song-1',
            position: const Duration(seconds: 8),
          ),
          isFalse,
        );

        now = now.add(const Duration(seconds: 8));
        expect(
          tracker.onPositionChanged(
            songId: 'song-1',
            position: const Duration(seconds: 16),
          ),
          isFalse,
        );

        now = now.add(const Duration(seconds: 8));
        expect(
          tracker.onPositionChanged(
            songId: 'song-1',
            position: const Duration(seconds: 24),
          ),
          isFalse,
        );

        now = now.add(const Duration(seconds: 8));
        expect(
          tracker.onPositionChanged(
            songId: 'song-1',
            position: const Duration(seconds: 32),
          ),
          isTrue,
        );
      },
    );

    test(
      'restarts the threshold when the same track is explicitly restarted',
      () {
        final tracker = ReplayPlayTracker();
        tracker.startTrack('song-1');

        for (var second = 1; second < 30; second++) {
          expect(
            tracker.onPositionChanged(
              songId: 'song-1',
              position: Duration(seconds: second),
            ),
            isFalse,
          );
        }

        tracker.startTrack('song-1');

        for (var second = 1; second < 30; second++) {
          expect(
            tracker.onPositionChanged(
              songId: 'song-1',
              position: Duration(seconds: second),
            ),
            isFalse,
          );
        }

        expect(
          tracker.onPositionChanged(
            songId: 'song-1',
            position: const Duration(seconds: 30),
          ),
          isTrue,
        );
      },
    );

    test(
      'syncing paused seeks updates the baseline without adding listen time',
      () {
        final tracker = ReplayPlayTracker();
        tracker.startTrack('song-1');

        for (var second = 1; second <= 10; second++) {
          expect(
            tracker.onPositionChanged(
              songId: 'song-1',
              position: Duration(seconds: second),
            ),
            isFalse,
          );
        }

        tracker.syncPosition(
          songId: 'song-1',
          position: const Duration(seconds: 25),
        );

        for (var second = 26; second < 45; second++) {
          expect(
            tracker.onPositionChanged(
              songId: 'song-1',
              position: Duration(seconds: second),
            ),
            isFalse,
          );
        }

        expect(
          tracker.onPositionChanged(
            songId: 'song-1',
            position: const Duration(seconds: 45),
          ),
          isTrue,
        );
      },
    );
  });
}
