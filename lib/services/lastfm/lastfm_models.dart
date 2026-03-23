import 'package:freezed_annotation/freezed_annotation.dart';

part 'lastfm_models.freezed.dart';
part 'lastfm_models.g.dart';

/// Represents Last.fm session state persisted after auth.
@freezed
abstract class LastFmSession with _$LastFmSession {
  const factory LastFmSession({
    required String sessionKey,
    required String username,
  }) = _LastFmSession;

  factory LastFmSession.fromJson(Map<String, dynamic> json) =>
      _$LastFmSessionFromJson(json);
}

/// A single track ready to be scrobbled.
/// Uses Unix timestamp (seconds since epoch) of when playback started.
@freezed
abstract class ScrobbleEntry with _$ScrobbleEntry {
  const factory ScrobbleEntry({
    required String artist,
    required String track,
    required int timestamp,
    String? album,
    String? albumArtist,
    int? durationSeconds,
  }) = _ScrobbleEntry;

  factory ScrobbleEntry.fromJson(Map<String, dynamic> json) =>
      _$ScrobbleEntryFromJson(json);
}
