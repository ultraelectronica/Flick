// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'lastfm_models.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$LastFmSession {

 String get sessionKey; String get username;
/// Create a copy of LastFmSession
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$LastFmSessionCopyWith<LastFmSession> get copyWith => _$LastFmSessionCopyWithImpl<LastFmSession>(this as LastFmSession, _$identity);

  /// Serializes this LastFmSession to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is LastFmSession&&(identical(other.sessionKey, sessionKey) || other.sessionKey == sessionKey)&&(identical(other.username, username) || other.username == username));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,sessionKey,username);

@override
String toString() {
  return 'LastFmSession(sessionKey: $sessionKey, username: $username)';
}


}

/// @nodoc
abstract mixin class $LastFmSessionCopyWith<$Res>  {
  factory $LastFmSessionCopyWith(LastFmSession value, $Res Function(LastFmSession) _then) = _$LastFmSessionCopyWithImpl;
@useResult
$Res call({
 String sessionKey, String username
});




}
/// @nodoc
class _$LastFmSessionCopyWithImpl<$Res>
    implements $LastFmSessionCopyWith<$Res> {
  _$LastFmSessionCopyWithImpl(this._self, this._then);

  final LastFmSession _self;
  final $Res Function(LastFmSession) _then;

/// Create a copy of LastFmSession
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? sessionKey = null,Object? username = null,}) {
  return _then(_self.copyWith(
sessionKey: null == sessionKey ? _self.sessionKey : sessionKey // ignore: cast_nullable_to_non_nullable
as String,username: null == username ? _self.username : username // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [LastFmSession].
extension LastFmSessionPatterns on LastFmSession {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _LastFmSession value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _LastFmSession() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _LastFmSession value)  $default,){
final _that = this;
switch (_that) {
case _LastFmSession():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _LastFmSession value)?  $default,){
final _that = this;
switch (_that) {
case _LastFmSession() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String sessionKey,  String username)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _LastFmSession() when $default != null:
return $default(_that.sessionKey,_that.username);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String sessionKey,  String username)  $default,) {final _that = this;
switch (_that) {
case _LastFmSession():
return $default(_that.sessionKey,_that.username);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String sessionKey,  String username)?  $default,) {final _that = this;
switch (_that) {
case _LastFmSession() when $default != null:
return $default(_that.sessionKey,_that.username);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _LastFmSession implements LastFmSession {
  const _LastFmSession({required this.sessionKey, required this.username});
  factory _LastFmSession.fromJson(Map<String, dynamic> json) => _$LastFmSessionFromJson(json);

@override final  String sessionKey;
@override final  String username;

/// Create a copy of LastFmSession
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$LastFmSessionCopyWith<_LastFmSession> get copyWith => __$LastFmSessionCopyWithImpl<_LastFmSession>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$LastFmSessionToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _LastFmSession&&(identical(other.sessionKey, sessionKey) || other.sessionKey == sessionKey)&&(identical(other.username, username) || other.username == username));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,sessionKey,username);

@override
String toString() {
  return 'LastFmSession(sessionKey: $sessionKey, username: $username)';
}


}

/// @nodoc
abstract mixin class _$LastFmSessionCopyWith<$Res> implements $LastFmSessionCopyWith<$Res> {
  factory _$LastFmSessionCopyWith(_LastFmSession value, $Res Function(_LastFmSession) _then) = __$LastFmSessionCopyWithImpl;
@override @useResult
$Res call({
 String sessionKey, String username
});




}
/// @nodoc
class __$LastFmSessionCopyWithImpl<$Res>
    implements _$LastFmSessionCopyWith<$Res> {
  __$LastFmSessionCopyWithImpl(this._self, this._then);

  final _LastFmSession _self;
  final $Res Function(_LastFmSession) _then;

/// Create a copy of LastFmSession
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? sessionKey = null,Object? username = null,}) {
  return _then(_LastFmSession(
sessionKey: null == sessionKey ? _self.sessionKey : sessionKey // ignore: cast_nullable_to_non_nullable
as String,username: null == username ? _self.username : username // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}


/// @nodoc
mixin _$ScrobbleEntry {

 String get artist; String get track; int get timestamp; String? get album; String? get albumArtist; int? get durationSeconds;
/// Create a copy of ScrobbleEntry
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ScrobbleEntryCopyWith<ScrobbleEntry> get copyWith => _$ScrobbleEntryCopyWithImpl<ScrobbleEntry>(this as ScrobbleEntry, _$identity);

  /// Serializes this ScrobbleEntry to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ScrobbleEntry&&(identical(other.artist, artist) || other.artist == artist)&&(identical(other.track, track) || other.track == track)&&(identical(other.timestamp, timestamp) || other.timestamp == timestamp)&&(identical(other.album, album) || other.album == album)&&(identical(other.albumArtist, albumArtist) || other.albumArtist == albumArtist)&&(identical(other.durationSeconds, durationSeconds) || other.durationSeconds == durationSeconds));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,artist,track,timestamp,album,albumArtist,durationSeconds);

@override
String toString() {
  return 'ScrobbleEntry(artist: $artist, track: $track, timestamp: $timestamp, album: $album, albumArtist: $albumArtist, durationSeconds: $durationSeconds)';
}


}

/// @nodoc
abstract mixin class $ScrobbleEntryCopyWith<$Res>  {
  factory $ScrobbleEntryCopyWith(ScrobbleEntry value, $Res Function(ScrobbleEntry) _then) = _$ScrobbleEntryCopyWithImpl;
@useResult
$Res call({
 String artist, String track, int timestamp, String? album, String? albumArtist, int? durationSeconds
});




}
/// @nodoc
class _$ScrobbleEntryCopyWithImpl<$Res>
    implements $ScrobbleEntryCopyWith<$Res> {
  _$ScrobbleEntryCopyWithImpl(this._self, this._then);

  final ScrobbleEntry _self;
  final $Res Function(ScrobbleEntry) _then;

/// Create a copy of ScrobbleEntry
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? artist = null,Object? track = null,Object? timestamp = null,Object? album = freezed,Object? albumArtist = freezed,Object? durationSeconds = freezed,}) {
  return _then(_self.copyWith(
artist: null == artist ? _self.artist : artist // ignore: cast_nullable_to_non_nullable
as String,track: null == track ? _self.track : track // ignore: cast_nullable_to_non_nullable
as String,timestamp: null == timestamp ? _self.timestamp : timestamp // ignore: cast_nullable_to_non_nullable
as int,album: freezed == album ? _self.album : album // ignore: cast_nullable_to_non_nullable
as String?,albumArtist: freezed == albumArtist ? _self.albumArtist : albumArtist // ignore: cast_nullable_to_non_nullable
as String?,durationSeconds: freezed == durationSeconds ? _self.durationSeconds : durationSeconds // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}

}


/// Adds pattern-matching-related methods to [ScrobbleEntry].
extension ScrobbleEntryPatterns on ScrobbleEntry {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ScrobbleEntry value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ScrobbleEntry() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ScrobbleEntry value)  $default,){
final _that = this;
switch (_that) {
case _ScrobbleEntry():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ScrobbleEntry value)?  $default,){
final _that = this;
switch (_that) {
case _ScrobbleEntry() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String artist,  String track,  int timestamp,  String? album,  String? albumArtist,  int? durationSeconds)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ScrobbleEntry() when $default != null:
return $default(_that.artist,_that.track,_that.timestamp,_that.album,_that.albumArtist,_that.durationSeconds);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String artist,  String track,  int timestamp,  String? album,  String? albumArtist,  int? durationSeconds)  $default,) {final _that = this;
switch (_that) {
case _ScrobbleEntry():
return $default(_that.artist,_that.track,_that.timestamp,_that.album,_that.albumArtist,_that.durationSeconds);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String artist,  String track,  int timestamp,  String? album,  String? albumArtist,  int? durationSeconds)?  $default,) {final _that = this;
switch (_that) {
case _ScrobbleEntry() when $default != null:
return $default(_that.artist,_that.track,_that.timestamp,_that.album,_that.albumArtist,_that.durationSeconds);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ScrobbleEntry implements ScrobbleEntry {
  const _ScrobbleEntry({required this.artist, required this.track, required this.timestamp, this.album, this.albumArtist, this.durationSeconds});
  factory _ScrobbleEntry.fromJson(Map<String, dynamic> json) => _$ScrobbleEntryFromJson(json);

@override final  String artist;
@override final  String track;
@override final  int timestamp;
@override final  String? album;
@override final  String? albumArtist;
@override final  int? durationSeconds;

/// Create a copy of ScrobbleEntry
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ScrobbleEntryCopyWith<_ScrobbleEntry> get copyWith => __$ScrobbleEntryCopyWithImpl<_ScrobbleEntry>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ScrobbleEntryToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ScrobbleEntry&&(identical(other.artist, artist) || other.artist == artist)&&(identical(other.track, track) || other.track == track)&&(identical(other.timestamp, timestamp) || other.timestamp == timestamp)&&(identical(other.album, album) || other.album == album)&&(identical(other.albumArtist, albumArtist) || other.albumArtist == albumArtist)&&(identical(other.durationSeconds, durationSeconds) || other.durationSeconds == durationSeconds));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,artist,track,timestamp,album,albumArtist,durationSeconds);

@override
String toString() {
  return 'ScrobbleEntry(artist: $artist, track: $track, timestamp: $timestamp, album: $album, albumArtist: $albumArtist, durationSeconds: $durationSeconds)';
}


}

/// @nodoc
abstract mixin class _$ScrobbleEntryCopyWith<$Res> implements $ScrobbleEntryCopyWith<$Res> {
  factory _$ScrobbleEntryCopyWith(_ScrobbleEntry value, $Res Function(_ScrobbleEntry) _then) = __$ScrobbleEntryCopyWithImpl;
@override @useResult
$Res call({
 String artist, String track, int timestamp, String? album, String? albumArtist, int? durationSeconds
});




}
/// @nodoc
class __$ScrobbleEntryCopyWithImpl<$Res>
    implements _$ScrobbleEntryCopyWith<$Res> {
  __$ScrobbleEntryCopyWithImpl(this._self, this._then);

  final _ScrobbleEntry _self;
  final $Res Function(_ScrobbleEntry) _then;

/// Create a copy of ScrobbleEntry
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? artist = null,Object? track = null,Object? timestamp = null,Object? album = freezed,Object? albumArtist = freezed,Object? durationSeconds = freezed,}) {
  return _then(_ScrobbleEntry(
artist: null == artist ? _self.artist : artist // ignore: cast_nullable_to_non_nullable
as String,track: null == track ? _self.track : track // ignore: cast_nullable_to_non_nullable
as String,timestamp: null == timestamp ? _self.timestamp : timestamp // ignore: cast_nullable_to_non_nullable
as int,album: freezed == album ? _self.album : album // ignore: cast_nullable_to_non_nullable
as String?,albumArtist: freezed == albumArtist ? _self.albumArtist : albumArtist // ignore: cast_nullable_to_non_nullable
as String?,durationSeconds: freezed == durationSeconds ? _self.durationSeconds : durationSeconds // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}


}

// dart format on
