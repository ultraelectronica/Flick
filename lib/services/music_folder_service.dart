import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'permission_service.dart';

/// Represents an audio file discovered during folder scanning.
class AudioFileInfo {
  final String uri;
  final String name;
  final int size;
  final int lastModified;
  final String? mimeType;
  final String extension;
  final String? title;
  final String? artist;
  final String? album;
  final int? duration;
  final String? albumArtPath;
  final String? bitrate;

  AudioFileInfo({
    required this.uri,
    required this.name,
    required this.size,
    required this.lastModified,
    this.mimeType,
    required this.extension,
    this.title,
    this.artist,
    this.album,
    this.duration,
    this.albumArtPath,
    this.bitrate,
  });

  factory AudioFileInfo.fromMap(Map<String, dynamic> map) {
    return AudioFileInfo(
      uri: map['uri'] as String,
      name:
          map['name'] as String? ??
          '', // Name might be null in metadata-only response
      size: (map['size'] as num?)?.toInt() ?? 0,
      lastModified: (map['lastModified'] as num?)?.toInt() ?? 0,
      mimeType: map['mimeType'] as String?,
      extension: map['extension'] as String? ?? '',
      title: map['title'] as String?,
      artist: map['artist'] as String?,
      album: map['album'] as String?,
      duration: map['duration'] != null
          ? (map['duration'] as num).toInt()
          : null,
      albumArtPath: map['albumArtPath'] as String?,
      bitrate: map['bitrate'] as String?,
    );
  }
}

/// Represents a watched music folder.
class MusicFolder {
  final String uri;
  final String displayName;
  final DateTime dateAdded;

  MusicFolder({
    required this.uri,
    required this.displayName,
    required this.dateAdded,
  });

  Map<String, dynamic> toJson() => {
    'uri': uri,
    'displayName': displayName,
    'dateAdded': dateAdded.millisecondsSinceEpoch,
  };

  factory MusicFolder.fromJson(Map<String, dynamic> json) {
    return MusicFolder(
      uri: json['uri'] as String,
      displayName: json['displayName'] as String,
      dateAdded: DateTime.fromMillisecondsSinceEpoch(json['dateAdded'] as int),
    );
  }
}

/// Service for managing music folders and their contents.
class MusicFolderService {
  static const _channel = MethodChannel('com.ultraelectronica.flick/storage');
  static const _prefKey = 'music_folders';

  final PermissionService _permissionService;

  MusicFolderService({PermissionService? permissionService})
    : _permissionService = permissionService ?? PermissionService();

  /// Add a new music folder using the system folder picker.
  /// Returns the added folder, or null if cancelled.
  Future<MusicFolder?> addFolder() async {
    // Open folder picker
    final uri = await _permissionService.openFolderPicker();
    if (uri == null) return null;

    // Take persistable permission
    final success = await _permissionService.takePersistablePermission(uri);
    if (!success) {
      throw StorageException('Failed to persist folder access');
    }

    // Get display name
    final displayName = await _getDisplayName(uri) ?? 'Unknown Folder';

    // Create folder object
    final folder = MusicFolder(
      uri: uri,
      displayName: displayName,
      dateAdded: DateTime.now(),
    );

    // Save to preferences
    await _saveFolderToPrefs(folder);

    return folder;
  }

  /// Remove a music folder and release its permission.
  Future<void> removeFolder(String uri) async {
    // Release permission
    await _permissionService.releasePersistablePermission(uri);

    // Remove from preferences
    await _removeFolderFromPrefs(uri);
  }

  /// Get all saved music folders.
  Future<List<MusicFolder>> getSavedFolders() async {
    final prefs = await SharedPreferences.getInstance();
    final foldersJson = prefs.getStringList(_prefKey) ?? [];

    final folders = <MusicFolder>[];
    for (final json in foldersJson) {
      try {
        final map = _parseJsonString(json);
        folders.add(MusicFolder.fromJson(map));
      } catch (e) {
        // Skip invalid entries
      }
    }
    return folders;
  }

  /// Scan a folder for audio files (Fast Scan - no metadata).
  /// Returns a list of discovered audio files with basic info.
  Future<List<AudioFileInfo>> scanFolder(String folderUri) async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>(
        'listAudioFiles',
        {'uri': folderUri},
      );

      if (result == null) return [];

      return result
          .cast<Map<dynamic, dynamic>>()
          .map((map) => AudioFileInfo.fromMap(map.cast<String, dynamic>()))
          .toList();
    } on PlatformException catch (e) {
      throw StorageException('Failed to scan folder: ${e.message}');
    }
  }

  /// Fetch rich metadata for a list of audio file URIs.
  Future<List<AudioFileInfo>> fetchMetadata(List<String> uris) async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>(
        'fetchAudioMetadata',
        {'uris': uris},
      );

      if (result == null) return [];

      return result
          .cast<Map<dynamic, dynamic>>()
          .map((map) => AudioFileInfo.fromMap(map.cast<String, dynamic>()))
          .toList();
    } on PlatformException catch (e) {
      throw StorageException('Failed to fetch metadata: ${e.message}');
    }
  }

  /// Scan all saved folders for audio files.
  Stream<AudioFileInfo> scanAllFolders() async* {
    final folders = await getSavedFolders();
    for (final folder in folders) {
      final files = await scanFolder(folder.uri);
      for (final file in files) {
        yield file;
      }
    }
  }

  Future<String?> _getDisplayName(String uri) async {
    try {
      return await _channel.invokeMethod<String>('getDocumentDisplayName', {
        'uri': uri,
      });
    } catch (e) {
      return null;
    }
  }

  Future<void> _saveFolderToPrefs(MusicFolder folder) async {
    final prefs = await SharedPreferences.getInstance();
    final foldersJson = prefs.getStringList(_prefKey) ?? [];

    // Check if folder already exists
    final existingIndex = foldersJson.indexWhere((json) {
      try {
        final map = _parseJsonString(json);
        return map['uri'] == folder.uri;
      } catch (e) {
        return false;
      }
    });

    final folderJson = _toJsonString(folder.toJson());

    if (existingIndex >= 0) {
      foldersJson[existingIndex] = folderJson;
    } else {
      foldersJson.add(folderJson);
    }

    await prefs.setStringList(_prefKey, foldersJson);
  }

  Future<void> _removeFolderFromPrefs(String uri) async {
    final prefs = await SharedPreferences.getInstance();
    final foldersJson = prefs.getStringList(_prefKey) ?? [];

    foldersJson.removeWhere((json) {
      try {
        final map = _parseJsonString(json);
        return map['uri'] == uri;
      } catch (e) {
        return false;
      }
    });

    await prefs.setStringList(_prefKey, foldersJson);
  }

  // Simple JSON encoding/decoding without importing dart:convert
  String _toJsonString(Map<String, dynamic> map) {
    final parts = map.entries.map((e) {
      final value = e.value;
      if (value is String) {
        return '"${e.key}":"${value.replaceAll('"', '\\"')}"';
      } else {
        return '"${e.key}":$value';
      }
    });
    return '{${parts.join(',')}}';
  }

  Map<String, dynamic> _parseJsonString(String json) {
    // Simple JSON parsing for our specific format
    final content = json.substring(1, json.length - 1); // Remove { }
    final result = <String, dynamic>{};

    // Parse key-value pairs (handles our specific format)
    final regex = RegExp(r'"(\w+)":((?:"[^"]*")|(?:\d+))');
    for (final match in regex.allMatches(content)) {
      final key = match.group(1)!;
      var value = match.group(2)!;

      if (value.startsWith('"') && value.endsWith('"')) {
        result[key] = value.substring(1, value.length - 1);
      } else {
        result[key] = int.parse(value);
      }
    }

    return result;
  }
}
