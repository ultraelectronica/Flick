import 'package:flick/models/playback_state.dart';
import 'package:flick/models/song.dart';

abstract class AudioEngine {
  Stream<PlaybackState> get playbackStateStream;

  Future<void> load(Song track);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> dispose();
}
