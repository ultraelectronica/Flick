class ReplayPlayTracker {
  ReplayPlayTracker({
    this.minimumPlayDuration = const Duration(seconds: 30),
    this.maxContinuousProgressGap = const Duration(seconds: 3),
  });

  final Duration minimumPlayDuration;
  final Duration maxContinuousProgressGap;

  String? _songId;
  int _lastPositionMs = 0;
  int _listenedMs = 0;
  bool _hasCountedCurrentTrack = false;

  void startTrack(String songId, {Duration initialPosition = Duration.zero}) {
    _songId = songId;
    _lastPositionMs = initialPosition.inMilliseconds;
    _listenedMs = 0;
    _hasCountedCurrentTrack = false;
  }

  void clear() {
    _songId = null;
    _lastPositionMs = 0;
    _listenedMs = 0;
    _hasCountedCurrentTrack = false;
  }

  void syncPosition({required String songId, required Duration position}) {
    if (_songId != songId) {
      startTrack(songId, initialPosition: position);
      return;
    }

    _lastPositionMs = position.inMilliseconds;
  }

  bool onPositionChanged({required String songId, required Duration position}) {
    if (_songId != songId) {
      startTrack(songId, initialPosition: position);
      return false;
    }

    final positionMs = position.inMilliseconds;
    final deltaMs = positionMs - _lastPositionMs;
    _lastPositionMs = positionMs;

    if (_hasCountedCurrentTrack ||
        deltaMs <= 0 ||
        deltaMs > maxContinuousProgressGap.inMilliseconds) {
      return false;
    }

    _listenedMs += deltaMs;
    if (_listenedMs < minimumPlayDuration.inMilliseconds) {
      return false;
    }

    _hasCountedCurrentTrack = true;
    return true;
  }
}
