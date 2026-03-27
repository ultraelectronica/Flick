import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'permission_service.dart';
import '../data/repositories/folder_repository.dart';
import '../data/entities/folder_entity.dart';

String normalizeFolderIdentifier(String uri) {
  final parsed = Uri.tryParse(uri);
  if (parsed != null && parsed.scheme == 'content') {
    final treeSegments = parsed.pathSegments;
    final treeIndex = treeSegments.indexOf('tree');
    if (treeIndex >= 0 && treeIndex + 1 < treeSegments.length) {
      final treeId = Uri.decodeComponent(
        treeSegments[treeIndex + 1],
      ).replaceAll('\\', '/').replaceAll(RegExp(r'/+'), '/').toLowerCase();
      if (treeId == '/' || treeId.endsWith(':')) {
        return treeId;
      }
      return treeId.replaceFirst(RegExp(r'/+$'), '');
    }
  }

  final normalized = uri
      .replaceAll('\\', '/')
      .replaceAll(RegExp(r'/+'), '/')
      .trim();
  if (normalized == '/') {
    return normalized;
  }
  return normalized.replaceFirst(RegExp(r'/$'), '').toLowerCase();
}

bool isSameOrDescendantFolder(String candidateUri, String rootUri) {
  final candidate = normalizeFolderIdentifier(candidateUri);
  final root = normalizeFolderIdentifier(rootUri);

  if (candidate == root) {
    return true;
  }
  if (root.isEmpty) {
    return false;
  }
  if (root == '/' || root.endsWith(':')) {
    return candidate.startsWith(root);
  }
  return candidate.startsWith('$root/');
}

bool foldersOverlap(String firstUri, String secondUri) {
  return isSameOrDescendantFolder(firstUri, secondUri) ||
      isSameOrDescendantFolder(secondUri, firstUri);
}

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
  final String? albumArtist;
  final int? trackNumber;
  final int? discNumber;
  final int? duration;
  final String? albumArtPath;
  final String? bitrate;
  final int? bitDepth;
  final int? sampleRate;

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
    this.albumArtist,
    this.trackNumber,
    this.discNumber,
    this.duration,
    this.albumArtPath,
    this.bitrate,
    this.bitDepth,
    this.sampleRate,
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
      albumArtist: map['albumArtist'] as String?,
      trackNumber: (map['trackNumber'] as num?)?.toInt(),
      discNumber: (map['discNumber'] as num?)?.toInt(),
      duration: map['duration'] != null
          ? (map['duration'] as num).toInt()
          : null,
      albumArtPath: map['albumArtPath'] as String?,
      bitrate: map['bitrate'] as String?,
      bitDepth: (map['bitDepth'] as num?)?.toInt(),
      sampleRate: (map['sampleRate'] as num?)?.toInt(),
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

/// Exception thrown when trying to add a folder that already exists.
class FolderAlreadyExistsException implements Exception {
  final String message;
  FolderAlreadyExistsException(this.message);
  @override
  String toString() => message;
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
  /// Throws [FolderAlreadyExistsException] if the folder is already added.
  Future<MusicFolder?> addFolder() async {
    // Open folder picker
    final uri = await _permissionService.openFolderPicker();
    if (uri == null) return null;

    // Check if folder already exists
    final existingFolders = await getSavedFolders();
    for (final folder in existingFolders) {
      if (folder.uri == uri) {
        throw FolderAlreadyExistsException(
          'This folder has already been added',
        );
      }
      if (foldersOverlap(folder.uri, uri)) {
        throw FolderAlreadyExistsException(
          'This folder overlaps with "${folder.displayName}". Keep only one root to avoid duplicate scans.',
        );
      }
    }

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

    // Save to preferences AND database
    await _saveFolderToPrefs(folder);
    await _saveFolderToDatabase(folder);

    return folder;
  }

  /// Remove a music folder and release its permission.
  Future<void> removeFolder(String uri) async {
    // Release permission
    await _permissionService.releasePersistablePermission(uri);

    // Remove from preferences AND database
    await _removeFolderFromPrefs(uri);
    await _removeFolderFromDatabase(uri);
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
    final scheduledRoots = <String>{};
    for (final folder in folders) {
      final normalized = normalizeFolderIdentifier(folder.uri);
      final overlapsExisting = scheduledRoots.any(
        (root) =>
            isSameOrDescendantFolder(normalized, root) ||
            isSameOrDescendantFolder(root, normalized),
      );
      if (overlapsExisting) {
        continue;
      }
      scheduledRoots.add(normalized);
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

  Future<void> _saveFolderToDatabase(MusicFolder folder) async {
    final repository = FolderRepository();
    final entity = FolderEntity()
      ..uri = folder.uri
      ..displayName = folder.displayName
      ..dateAdded = folder.dateAdded
      ..songCount = 0;
    await repository.upsertFolder(entity);
  }

  Future<void> _removeFolderFromDatabase(String uri) async {
    final repository = FolderRepository();
    await repository.deleteFolder(uri);
  }
}
