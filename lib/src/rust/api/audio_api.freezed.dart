// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'audio_api.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$AudioEventType {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AudioEventType);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'AudioEventType()';
}


}

/// @nodoc
class $AudioEventTypeCopyWith<$Res>  {
$AudioEventTypeCopyWith(AudioEventType _, $Res Function(AudioEventType) __);
}


/// Adds pattern-matching-related methods to [AudioEventType].
extension AudioEventTypePatterns on AudioEventType {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( AudioEventType_StateChanged value)?  stateChanged,TResult Function( AudioEventType_Progress value)?  progress,TResult Function( AudioEventType_TrackEnded value)?  trackEnded,TResult Function( AudioEventType_CrossfadeStarted value)?  crossfadeStarted,TResult Function( AudioEventType_Error value)?  error,TResult Function( AudioEventType_NextTrackReady value)?  nextTrackReady,required TResult orElse(),}){
final _that = this;
switch (_that) {
case AudioEventType_StateChanged() when stateChanged != null:
return stateChanged(_that);case AudioEventType_Progress() when progress != null:
return progress(_that);case AudioEventType_TrackEnded() when trackEnded != null:
return trackEnded(_that);case AudioEventType_CrossfadeStarted() when crossfadeStarted != null:
return crossfadeStarted(_that);case AudioEventType_Error() when error != null:
return error(_that);case AudioEventType_NextTrackReady() when nextTrackReady != null:
return nextTrackReady(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( AudioEventType_StateChanged value)  stateChanged,required TResult Function( AudioEventType_Progress value)  progress,required TResult Function( AudioEventType_TrackEnded value)  trackEnded,required TResult Function( AudioEventType_CrossfadeStarted value)  crossfadeStarted,required TResult Function( AudioEventType_Error value)  error,required TResult Function( AudioEventType_NextTrackReady value)  nextTrackReady,}){
final _that = this;
switch (_that) {
case AudioEventType_StateChanged():
return stateChanged(_that);case AudioEventType_Progress():
return progress(_that);case AudioEventType_TrackEnded():
return trackEnded(_that);case AudioEventType_CrossfadeStarted():
return crossfadeStarted(_that);case AudioEventType_Error():
return error(_that);case AudioEventType_NextTrackReady():
return nextTrackReady(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( AudioEventType_StateChanged value)?  stateChanged,TResult? Function( AudioEventType_Progress value)?  progress,TResult? Function( AudioEventType_TrackEnded value)?  trackEnded,TResult? Function( AudioEventType_CrossfadeStarted value)?  crossfadeStarted,TResult? Function( AudioEventType_Error value)?  error,TResult? Function( AudioEventType_NextTrackReady value)?  nextTrackReady,}){
final _that = this;
switch (_that) {
case AudioEventType_StateChanged() when stateChanged != null:
return stateChanged(_that);case AudioEventType_Progress() when progress != null:
return progress(_that);case AudioEventType_TrackEnded() when trackEnded != null:
return trackEnded(_that);case AudioEventType_CrossfadeStarted() when crossfadeStarted != null:
return crossfadeStarted(_that);case AudioEventType_Error() when error != null:
return error(_that);case AudioEventType_NextTrackReady() when nextTrackReady != null:
return nextTrackReady(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String state)?  stateChanged,TResult Function( double positionSecs,  double? durationSecs,  double bufferLevel)?  progress,TResult Function( String path)?  trackEnded,TResult Function( String fromPath,  String toPath)?  crossfadeStarted,TResult Function( String message)?  error,TResult Function( String path)?  nextTrackReady,required TResult orElse(),}) {final _that = this;
switch (_that) {
case AudioEventType_StateChanged() when stateChanged != null:
return stateChanged(_that.state);case AudioEventType_Progress() when progress != null:
return progress(_that.positionSecs,_that.durationSecs,_that.bufferLevel);case AudioEventType_TrackEnded() when trackEnded != null:
return trackEnded(_that.path);case AudioEventType_CrossfadeStarted() when crossfadeStarted != null:
return crossfadeStarted(_that.fromPath,_that.toPath);case AudioEventType_Error() when error != null:
return error(_that.message);case AudioEventType_NextTrackReady() when nextTrackReady != null:
return nextTrackReady(_that.path);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String state)  stateChanged,required TResult Function( double positionSecs,  double? durationSecs,  double bufferLevel)  progress,required TResult Function( String path)  trackEnded,required TResult Function( String fromPath,  String toPath)  crossfadeStarted,required TResult Function( String message)  error,required TResult Function( String path)  nextTrackReady,}) {final _that = this;
switch (_that) {
case AudioEventType_StateChanged():
return stateChanged(_that.state);case AudioEventType_Progress():
return progress(_that.positionSecs,_that.durationSecs,_that.bufferLevel);case AudioEventType_TrackEnded():
return trackEnded(_that.path);case AudioEventType_CrossfadeStarted():
return crossfadeStarted(_that.fromPath,_that.toPath);case AudioEventType_Error():
return error(_that.message);case AudioEventType_NextTrackReady():
return nextTrackReady(_that.path);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String state)?  stateChanged,TResult? Function( double positionSecs,  double? durationSecs,  double bufferLevel)?  progress,TResult? Function( String path)?  trackEnded,TResult? Function( String fromPath,  String toPath)?  crossfadeStarted,TResult? Function( String message)?  error,TResult? Function( String path)?  nextTrackReady,}) {final _that = this;
switch (_that) {
case AudioEventType_StateChanged() when stateChanged != null:
return stateChanged(_that.state);case AudioEventType_Progress() when progress != null:
return progress(_that.positionSecs,_that.durationSecs,_that.bufferLevel);case AudioEventType_TrackEnded() when trackEnded != null:
return trackEnded(_that.path);case AudioEventType_CrossfadeStarted() when crossfadeStarted != null:
return crossfadeStarted(_that.fromPath,_that.toPath);case AudioEventType_Error() when error != null:
return error(_that.message);case AudioEventType_NextTrackReady() when nextTrackReady != null:
return nextTrackReady(_that.path);case _:
  return null;

}
}

}

/// @nodoc


class AudioEventType_StateChanged extends AudioEventType {
  const AudioEventType_StateChanged({required this.state}): super._();
  

 final  String state;

/// Create a copy of AudioEventType
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AudioEventType_StateChangedCopyWith<AudioEventType_StateChanged> get copyWith => _$AudioEventType_StateChangedCopyWithImpl<AudioEventType_StateChanged>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AudioEventType_StateChanged&&(identical(other.state, state) || other.state == state));
}


@override
int get hashCode => Object.hash(runtimeType,state);

@override
String toString() {
  return 'AudioEventType.stateChanged(state: $state)';
}


}

/// @nodoc
abstract mixin class $AudioEventType_StateChangedCopyWith<$Res> implements $AudioEventTypeCopyWith<$Res> {
  factory $AudioEventType_StateChangedCopyWith(AudioEventType_StateChanged value, $Res Function(AudioEventType_StateChanged) _then) = _$AudioEventType_StateChangedCopyWithImpl;
@useResult
$Res call({
 String state
});




}
/// @nodoc
class _$AudioEventType_StateChangedCopyWithImpl<$Res>
    implements $AudioEventType_StateChangedCopyWith<$Res> {
  _$AudioEventType_StateChangedCopyWithImpl(this._self, this._then);

  final AudioEventType_StateChanged _self;
  final $Res Function(AudioEventType_StateChanged) _then;

/// Create a copy of AudioEventType
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? state = null,}) {
  return _then(AudioEventType_StateChanged(
state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class AudioEventType_Progress extends AudioEventType {
  const AudioEventType_Progress({required this.positionSecs, this.durationSecs, required this.bufferLevel}): super._();
  

 final  double positionSecs;
 final  double? durationSecs;
 final  double bufferLevel;

/// Create a copy of AudioEventType
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AudioEventType_ProgressCopyWith<AudioEventType_Progress> get copyWith => _$AudioEventType_ProgressCopyWithImpl<AudioEventType_Progress>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AudioEventType_Progress&&(identical(other.positionSecs, positionSecs) || other.positionSecs == positionSecs)&&(identical(other.durationSecs, durationSecs) || other.durationSecs == durationSecs)&&(identical(other.bufferLevel, bufferLevel) || other.bufferLevel == bufferLevel));
}


@override
int get hashCode => Object.hash(runtimeType,positionSecs,durationSecs,bufferLevel);

@override
String toString() {
  return 'AudioEventType.progress(positionSecs: $positionSecs, durationSecs: $durationSecs, bufferLevel: $bufferLevel)';
}


}

/// @nodoc
abstract mixin class $AudioEventType_ProgressCopyWith<$Res> implements $AudioEventTypeCopyWith<$Res> {
  factory $AudioEventType_ProgressCopyWith(AudioEventType_Progress value, $Res Function(AudioEventType_Progress) _then) = _$AudioEventType_ProgressCopyWithImpl;
@useResult
$Res call({
 double positionSecs, double? durationSecs, double bufferLevel
});




}
/// @nodoc
class _$AudioEventType_ProgressCopyWithImpl<$Res>
    implements $AudioEventType_ProgressCopyWith<$Res> {
  _$AudioEventType_ProgressCopyWithImpl(this._self, this._then);

  final AudioEventType_Progress _self;
  final $Res Function(AudioEventType_Progress) _then;

/// Create a copy of AudioEventType
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? positionSecs = null,Object? durationSecs = freezed,Object? bufferLevel = null,}) {
  return _then(AudioEventType_Progress(
positionSecs: null == positionSecs ? _self.positionSecs : positionSecs // ignore: cast_nullable_to_non_nullable
as double,durationSecs: freezed == durationSecs ? _self.durationSecs : durationSecs // ignore: cast_nullable_to_non_nullable
as double?,bufferLevel: null == bufferLevel ? _self.bufferLevel : bufferLevel // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}

/// @nodoc


class AudioEventType_TrackEnded extends AudioEventType {
  const AudioEventType_TrackEnded({required this.path}): super._();
  

 final  String path;

/// Create a copy of AudioEventType
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AudioEventType_TrackEndedCopyWith<AudioEventType_TrackEnded> get copyWith => _$AudioEventType_TrackEndedCopyWithImpl<AudioEventType_TrackEnded>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AudioEventType_TrackEnded&&(identical(other.path, path) || other.path == path));
}


@override
int get hashCode => Object.hash(runtimeType,path);

@override
String toString() {
  return 'AudioEventType.trackEnded(path: $path)';
}


}

/// @nodoc
abstract mixin class $AudioEventType_TrackEndedCopyWith<$Res> implements $AudioEventTypeCopyWith<$Res> {
  factory $AudioEventType_TrackEndedCopyWith(AudioEventType_TrackEnded value, $Res Function(AudioEventType_TrackEnded) _then) = _$AudioEventType_TrackEndedCopyWithImpl;
@useResult
$Res call({
 String path
});




}
/// @nodoc
class _$AudioEventType_TrackEndedCopyWithImpl<$Res>
    implements $AudioEventType_TrackEndedCopyWith<$Res> {
  _$AudioEventType_TrackEndedCopyWithImpl(this._self, this._then);

  final AudioEventType_TrackEnded _self;
  final $Res Function(AudioEventType_TrackEnded) _then;

/// Create a copy of AudioEventType
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? path = null,}) {
  return _then(AudioEventType_TrackEnded(
path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class AudioEventType_CrossfadeStarted extends AudioEventType {
  const AudioEventType_CrossfadeStarted({required this.fromPath, required this.toPath}): super._();
  

 final  String fromPath;
 final  String toPath;

/// Create a copy of AudioEventType
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AudioEventType_CrossfadeStartedCopyWith<AudioEventType_CrossfadeStarted> get copyWith => _$AudioEventType_CrossfadeStartedCopyWithImpl<AudioEventType_CrossfadeStarted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AudioEventType_CrossfadeStarted&&(identical(other.fromPath, fromPath) || other.fromPath == fromPath)&&(identical(other.toPath, toPath) || other.toPath == toPath));
}


@override
int get hashCode => Object.hash(runtimeType,fromPath,toPath);

@override
String toString() {
  return 'AudioEventType.crossfadeStarted(fromPath: $fromPath, toPath: $toPath)';
}


}

/// @nodoc
abstract mixin class $AudioEventType_CrossfadeStartedCopyWith<$Res> implements $AudioEventTypeCopyWith<$Res> {
  factory $AudioEventType_CrossfadeStartedCopyWith(AudioEventType_CrossfadeStarted value, $Res Function(AudioEventType_CrossfadeStarted) _then) = _$AudioEventType_CrossfadeStartedCopyWithImpl;
@useResult
$Res call({
 String fromPath, String toPath
});




}
/// @nodoc
class _$AudioEventType_CrossfadeStartedCopyWithImpl<$Res>
    implements $AudioEventType_CrossfadeStartedCopyWith<$Res> {
  _$AudioEventType_CrossfadeStartedCopyWithImpl(this._self, this._then);

  final AudioEventType_CrossfadeStarted _self;
  final $Res Function(AudioEventType_CrossfadeStarted) _then;

/// Create a copy of AudioEventType
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? fromPath = null,Object? toPath = null,}) {
  return _then(AudioEventType_CrossfadeStarted(
fromPath: null == fromPath ? _self.fromPath : fromPath // ignore: cast_nullable_to_non_nullable
as String,toPath: null == toPath ? _self.toPath : toPath // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class AudioEventType_Error extends AudioEventType {
  const AudioEventType_Error({required this.message}): super._();
  

 final  String message;

/// Create a copy of AudioEventType
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AudioEventType_ErrorCopyWith<AudioEventType_Error> get copyWith => _$AudioEventType_ErrorCopyWithImpl<AudioEventType_Error>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AudioEventType_Error&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode => Object.hash(runtimeType,message);

@override
String toString() {
  return 'AudioEventType.error(message: $message)';
}


}

/// @nodoc
abstract mixin class $AudioEventType_ErrorCopyWith<$Res> implements $AudioEventTypeCopyWith<$Res> {
  factory $AudioEventType_ErrorCopyWith(AudioEventType_Error value, $Res Function(AudioEventType_Error) _then) = _$AudioEventType_ErrorCopyWithImpl;
@useResult
$Res call({
 String message
});




}
/// @nodoc
class _$AudioEventType_ErrorCopyWithImpl<$Res>
    implements $AudioEventType_ErrorCopyWith<$Res> {
  _$AudioEventType_ErrorCopyWithImpl(this._self, this._then);

  final AudioEventType_Error _self;
  final $Res Function(AudioEventType_Error) _then;

/// Create a copy of AudioEventType
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? message = null,}) {
  return _then(AudioEventType_Error(
message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class AudioEventType_NextTrackReady extends AudioEventType {
  const AudioEventType_NextTrackReady({required this.path}): super._();
  

 final  String path;

/// Create a copy of AudioEventType
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AudioEventType_NextTrackReadyCopyWith<AudioEventType_NextTrackReady> get copyWith => _$AudioEventType_NextTrackReadyCopyWithImpl<AudioEventType_NextTrackReady>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AudioEventType_NextTrackReady&&(identical(other.path, path) || other.path == path));
}


@override
int get hashCode => Object.hash(runtimeType,path);

@override
String toString() {
  return 'AudioEventType.nextTrackReady(path: $path)';
}


}

/// @nodoc
abstract mixin class $AudioEventType_NextTrackReadyCopyWith<$Res> implements $AudioEventTypeCopyWith<$Res> {
  factory $AudioEventType_NextTrackReadyCopyWith(AudioEventType_NextTrackReady value, $Res Function(AudioEventType_NextTrackReady) _then) = _$AudioEventType_NextTrackReadyCopyWithImpl;
@useResult
$Res call({
 String path
});




}
/// @nodoc
class _$AudioEventType_NextTrackReadyCopyWithImpl<$Res>
    implements $AudioEventType_NextTrackReadyCopyWith<$Res> {
  _$AudioEventType_NextTrackReadyCopyWithImpl(this._self, this._then);

  final AudioEventType_NextTrackReady _self;
  final $Res Function(AudioEventType_NextTrackReady) _then;

/// Create a copy of AudioEventType
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? path = null,}) {
  return _then(AudioEventType_NextTrackReady(
path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
