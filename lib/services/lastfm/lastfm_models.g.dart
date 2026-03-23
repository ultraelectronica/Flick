// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'lastfm_models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_LastFmSession _$LastFmSessionFromJson(Map<String, dynamic> json) =>
    _LastFmSession(
      sessionKey: json['sessionKey'] as String,
      username: json['username'] as String,
    );

Map<String, dynamic> _$LastFmSessionToJson(_LastFmSession instance) =>
    <String, dynamic>{
      'sessionKey': instance.sessionKey,
      'username': instance.username,
    };

_ScrobbleEntry _$ScrobbleEntryFromJson(Map<String, dynamic> json) =>
    _ScrobbleEntry(
      artist: json['artist'] as String,
      track: json['track'] as String,
      timestamp: (json['timestamp'] as num).toInt(),
      album: json['album'] as String?,
      albumArtist: json['albumArtist'] as String?,
      durationSeconds: (json['durationSeconds'] as num?)?.toInt(),
    );

Map<String, dynamic> _$ScrobbleEntryToJson(_ScrobbleEntry instance) =>
    <String, dynamic>{
      'artist': instance.artist,
      'track': instance.track,
      'timestamp': instance.timestamp,
      'album': instance.album,
      'albumArtist': instance.albumArtist,
      'durationSeconds': instance.durationSeconds,
    };
