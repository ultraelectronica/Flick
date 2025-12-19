import 'package:isar_community/isar.dart';

import '../database.dart';
import '../../models/song.dart';

/// Repository for song CRUD operations.
class SongRepository {
  final Isar _isar;

  SongRepository({Isar? isar}) : _isar = isar ?? Database.instance;

  /// Get all songs ordered by title.
  Future<List<Song>> getAllSongs() async {
    final entities = await _isar.songEntitys.where().sortByTitle().findAll();
    return entities.map(_entityToSong).toList();
  }

  /// Get songs by folder URI.
  Future<List<Song>> getSongsByFolder(String folderUri) async {
    final entities = await _isar.songEntitys
        .filter()
        .folderUriEqualTo(folderUri)
        .sortByTitle()
        .findAll();
    return entities.map(_entityToSong).toList();
  }

  /// Get song entities by folder URI (internal use for scanning).
  Future<List<SongEntity>> getSongEntitiesByFolder(String folderUri) async {
    return await _isar.songEntitys
        .filter()
        .folderUriEqualTo(folderUri)
        .findAll();
  }

  /// Search songs by title, artist, or album.
  Future<List<Song>> searchSongs(String query) async {
    final lowerQuery = query.toLowerCase();
    final entities = await _isar.songEntitys
        .filter()
        .titleContains(lowerQuery, caseSensitive: false)
        .or()
        .artistContains(lowerQuery, caseSensitive: false)
        .or()
        .albumContains(lowerQuery, caseSensitive: false)
        .sortByTitle()
        .findAll();
    return entities.map(_entityToSong).toList();
  }

  /// Get song count.
  Future<int> getSongCount() async {
    return await _isar.songEntitys.count();
  }

  /// Add or update a song.
  Future<void> upsertSong(SongEntity entity) async {
    await _isar.writeTxn(() async {
      // Check if song with same file path exists
      final existing = await _isar.songEntitys
          .filter()
          .filePathEqualTo(entity.filePath)
          .findFirst();

      if (existing != null) {
        entity.id = existing.id;
      }

      await _isar.songEntitys.put(entity);
    });
  }

  /// Add multiple songs in a batch.
  Future<void> upsertSongs(List<SongEntity> entities) async {
    await _isar.writeTxn(() async {
      for (final entity in entities) {
        final existing = await _isar.songEntitys
            .filter()
            .filePathEqualTo(entity.filePath)
            .findFirst();

        if (existing != null) {
          entity.id = existing.id;
        }
      }
      await _isar.songEntitys.putAll(entities);
    });
  }

  /// Delete a song by ID.
  Future<void> deleteSong(int id) async {
    await _isar.writeTxn(() async {
      await _isar.songEntitys.delete(id);
    });
  }

  /// Delete all songs for a specific folder.
  Future<void> deleteSongsForFolder(String folderUri) async {
    await _isar.writeTxn(() async {
      await _isar.songEntitys.filter().folderUriEqualTo(folderUri).deleteAll();
    });
  }

  /// Get all song entities (internal use)
  Future<List<SongEntity>> getAllSongEntities() async {
    return await _isar.songEntitys.where().findAll();
  }

  /// Delete songs by their file paths.
  Future<void> deleteSongsByPath(List<String> paths) async {
    await _isar.writeTxn(() async {
      // Isar doesn't support 'in' clause for string indexes easily in one go without query loop or huge generic 'or'
      // Optimally, we delete by ID, but we have paths.
      // Let's find IDs first.
      // For large lists, chunking might be needed, but Isar is fast.
      // Alternative: logical OR.

      // If list is small, loop delete is fine. If large, batch.
      // Let's do a simple loop for now as deletions are usually rare/few.
      for (final path in paths) {
        await _isar.songEntitys.filter().filePathEqualTo(path).deleteAll();
      }
    });
  }

  /// Count songs in a folder.
  Future<int> countSongsInFolder(String folderUri) async {
    return await _isar.songEntitys.filter().folderUriEqualTo(folderUri).count();
  }

  /// Delete all songs.
  Future<void> deleteAllSongs() async {
    await _isar.writeTxn(() async {
      await _isar.songEntitys.clear();
    });
  }

  /// Watch for changes in the songs collection.
  Stream<void> watchSongs() {
    return _isar.songEntitys.watchLazy();
  }

  /// Convert entity to Song model.
  Song _entityToSong(SongEntity entity) {
    return Song(
      id: entity.id.toString(),
      title: entity.title,
      artist: entity.artist,
      albumArt: entity.albumArtPath,
      duration: Duration(milliseconds: entity.durationMs ?? 0),
      fileType: entity.fileType ?? 'unknown',
      resolution: _buildResolutionString(entity),
      album: entity.album,
      filePath: entity.filePath,
      dateAdded: entity.dateAdded,
    );
  }

  /// Build a resolution string from entity properties.
  String _buildResolutionString(SongEntity entity) {
    final parts = <String>[];
    if (entity.bitrate != null) {
      parts.add('${entity.bitrate}kbps');
    }
    if (entity.sampleRate != null) {
      parts.add('${entity.sampleRate}Hz');
    }
    if (entity.bitDepth != null) {
      parts.add('${entity.bitDepth}bit');
    }
    return parts.isEmpty ? 'Unknown' : parts.join(' / ');
  }
}
