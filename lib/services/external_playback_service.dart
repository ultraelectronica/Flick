import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flick/core/utils/audio_metadata_utils.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/music_folder_service.dart';
import 'package:flick/services/player_service.dart';

class ExternalPlaybackService {
  ExternalPlaybackService._();

  static final ExternalPlaybackService _instance = ExternalPlaybackService._();
  static const _channel = MethodChannel(
    'com.ultraelectronica.flick/integration',
  );
  static const _lockerPackage = 'com.ultraelectronica.locker';

  factory ExternalPlaybackService() => _instance;

  final MusicFolderService _musicFolderService = MusicFolderService();
  bool _initialized = false;

  Future<bool> initialize() async {
    if (!_initialized) {
      _channel.setMethodCallHandler(_handleMethodCall);
      _initialized = true;
    }

    return _consumePendingExternalPlayback();
  }

  Future<bool> returnToLocker() async {
    try {
      return await _channel.invokeMethod<bool>('returnToLocker') ?? false;
    } on PlatformException catch (e) {
      debugPrint('Failed to return to Locker: ${e.message}');
      return false;
    }
  }

  Future<bool> _consumePendingExternalPlayback() async {
    try {
      final payload = await _channel.invokeMapMethod<dynamic, dynamic>(
        'consumePendingExternalPlayback',
      );
      if (payload == null) {
        return false;
      }
      return _playExternalPayload(payload.cast<String, dynamic>());
    } on PlatformException catch (e) {
      debugPrint('Failed to consume pending external playback: ${e.message}');
      return false;
    }
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (call.method != 'externalPlaybackIntent') {
      throw MissingPluginException(
        'Unhandled integration method: ${call.method}',
      );
    }

    final arguments = call.arguments;
    if (arguments is! Map) {
      return false;
    }

    return _playExternalPayload(arguments.cast<String, dynamic>());
  }

  Future<bool> _playExternalPayload(Map<String, dynamic> payload) async {
    final uri = payload['uri'] as String?;
    if (uri == null || uri.isEmpty) {
      return false;
    }

    try {
      final metadataList = await _musicFolderService.fetchMetadata([uri]);
      final metadata = metadataList.isNotEmpty ? metadataList.first : null;
      final displayName = payload['displayName'] as String?;
      final mimeType = payload['mimeType'] as String?;
      final sourcePackage =
          (payload['sourcePackage'] as String?) ??
          ((payload['fromLocker'] == true) ? _lockerPackage : null);
      final song = Song(
        id: 'external:${DateTime.now().microsecondsSinceEpoch}:$uri',
        title: _resolveTitle(metadata?.title, displayName, uri),
        artist: metadata?.artist?.trim().isNotEmpty == true
            ? metadata!.artist!.trim()
            : 'Unknown artist',
        albumArt: metadata?.albumArtPath,
        duration: Duration(milliseconds: metadata?.duration ?? 0),
        fileType: _resolveFileType(metadata?.extension, mimeType, uri),
        resolution: _resolveResolution(
          bitrate: metadata?.bitrate,
          sampleRate: metadata?.sampleRate,
          bitDepth: metadata?.bitDepth,
        ),
        sampleRate: metadata?.sampleRate,
        bitDepth: metadata?.bitDepth,
        album: metadata?.album,
        albumArtist: metadata?.albumArtist,
        trackNumber: metadata?.trackNumber,
        discNumber: metadata?.discNumber,
        filePath: uri,
        isExternal: true,
        sourcePackage: sourcePackage,
      );

      await PlayerService().play(song, playlist: [song]);
      return true;
    } catch (e, stackTrace) {
      debugPrint('Failed to start external playback for $uri: $e');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  String _resolveTitle(String? title, String? displayName, String uri) {
    final trimmedTitle = title?.trim();
    if (trimmedTitle != null && trimmedTitle.isNotEmpty) {
      return trimmedTitle;
    }

    final trimmedDisplayName = displayName?.trim();
    if (trimmedDisplayName != null && trimmedDisplayName.isNotEmpty) {
      return trimmedDisplayName;
    }

    final pathSegments = Uri.tryParse(uri)?.pathSegments ?? const <String>[];
    final fallback = pathSegments.isNotEmpty ? pathSegments.last : null;
    return fallback == null || fallback.isEmpty ? 'Unknown track' : fallback;
  }

  String _resolveFileType(String? extension, String? mimeType, String uri) {
    final normalized = _canonicalPlaybackFileType(
      fileType: extension ?? mimeType ?? '',
      filePath: uri,
    );
    if (normalized.isNotEmpty) {
      return normalized.toUpperCase();
    }

    return 'AUDIO';
  }

  String? _resolveResolution({
    String? bitrate,
    int? sampleRate,
    int? bitDepth,
  }) {
    if (sampleRate != null &&
        sampleRate > 0 &&
        bitDepth != null &&
        bitDepth > 0) {
      final sampleRateLabel = sampleRate % 1000 == 0
          ? '${sampleRate ~/ 1000}kHz'
          : '${(sampleRate / 1000).toStringAsFixed(1)}kHz';
      return '$bitDepth-bit/$sampleRateLabel';
    }

    final bitrateValue = int.tryParse(bitrate ?? '');
    return AudioMetadataUtils.formatBitrateLabel(
      bitrateValue,
      sampleRate: sampleRate,
      bitDepth: bitDepth,
    );
  }

  bool isLockerSession(Song? song) {
    return song?.isExternal == true && song?.sourcePackage == _lockerPackage;
  }
}

String _canonicalPlaybackFileType({
  required String fileType,
  String? filePath,
}) {
  final pathExtension = _extractPlaybackPathExtension(filePath);
  final candidates = <String>[
    if (pathExtension.isNotEmpty) pathExtension,
    if (fileType.trim().isNotEmpty) fileType,
  ];

  for (final candidate in candidates) {
    final normalized = _normalizePlaybackFileTypeCandidate(candidate);
    if (normalized.isNotEmpty) {
      return normalized;
    }
  }

  return '';
}

String _extractPlaybackPathExtension(String? path) {
  if (path == null || path.isEmpty) return '';

  final withoutQuery = path.split('?').first.split('#').first;
  final dotIndex = withoutQuery.lastIndexOf('.');
  if (dotIndex < 0 || dotIndex >= withoutQuery.length - 1) return '';
  return withoutQuery.substring(dotIndex + 1).toLowerCase();
}

String _normalizePlaybackFileTypeCandidate(String rawValue) {
  var token = rawValue.trim().toLowerCase();
  if (token.isEmpty) return '';

  final separatorIndex = token.indexOf(';');
  if (separatorIndex >= 0) {
    token = token.substring(0, separatorIndex);
  }

  final slashIndex = token.lastIndexOf('/');
  if (slashIndex >= 0 && slashIndex < token.length - 1) {
    token = token.substring(slashIndex + 1);
  }

  token = token.replaceFirst(RegExp(r'^\.+'), '');
  token = token.trim();

  switch (token) {
    case 'aif':
    case 'aiff':
    case 'x-aiff':
      return 'aiff';
    case 'alac':
    case 'm4a':
    case 'mp4':
    case 'x-m4a':
      return 'm4a';
    case 'ogg':
    case 'oga':
    case 'vorbis':
      return 'ogg';
    case 'ogx':
      return 'ogx';
    case 'opus':
      return 'opus';
    case 'wave':
      return 'wav';
    default:
      return token;
  }
}
