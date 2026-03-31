import 'package:isar_community/isar.dart';

import '../database.dart';
import '../../models/song.dart';

class AlbumGroup {
  final String key;
  final String albumName;
  final String albumArtist;
  final List<Song> songs;

  const AlbumGroup({
    required this.key,
    required this.albumName,
    required this.albumArtist,
    required this.songs,
  });
}

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
    if (entities.isEmpty) return;

    await _isar.writeTxn(() async {
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
      for (final path in paths) {
        await _isar.songEntitys.filter().filePathEqualTo(path).deleteAll();
      }
    });
  }

  Future<void> deleteSongsByIds(List<Id> ids) async {
    if (ids.isEmpty) return;

    await _isar.writeTxn(() async {
      await _isar.songEntitys.deleteAll(ids);
    });
  }

  Future<void> updateAlbumArtPath(String filePath, String? albumArtPath) async {
    await _isar.writeTxn(() async {
      final existing = await _isar.songEntitys
          .filter()
          .filePathEqualTo(filePath)
          .findFirst();
      if (existing == null) {
        return;
      }

      if (existing.albumArtPath == albumArtPath) {
        return;
      }

      existing.albumArtPath = albumArtPath;
      await _isar.songEntitys.put(existing);
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

  /// Get all unique albums with their songs.
  Future<Map<String, List<Song>>> getSongsByAlbum() async {
    final songs = await getAllSongs();
    final albumMap = <String, List<Song>>{};
    for (final song in songs) {
      final album = song.album ?? 'Unknown Album';
      albumMap.putIfAbsent(album, () => []).add(song);
    }
    for (final albumSongs in albumMap.values) {
      albumSongs.sort(_compareAlbumSongs);
    }
    return albumMap;
  }

  Future<List<AlbumGroup>> getAlbumGroups() async {
    final songs = await getAllSongs();
    final groupedSongs = <String, List<Song>>{};
    final albumNames = <String, String>{};
    final albumArtists = <String, String>{};

    for (final song in songs) {
      final albumName = _albumNameForSong(song);
      final albumArtist = _albumArtistForSong(song);
      final key = _albumGroupKey(albumName, albumArtist);

      groupedSongs.putIfAbsent(key, () => []).add(song);
      albumNames[key] = albumName;
      albumArtists[key] = albumArtist;
    }

    final groups = groupedSongs.entries.map((entry) {
      final songs = List<Song>.from(entry.value)..sort(_compareAlbumSongs);
      return AlbumGroup(
        key: entry.key,
        albumName: albumNames[entry.key] ?? 'Unknown Album',
        albumArtist: albumArtists[entry.key] ?? 'Unknown Artist',
        songs: songs,
      );
    }).toList();

    groups.sort((a, b) {
      final artistCompare = a.albumArtist.compareTo(b.albumArtist);
      if (artistCompare != 0) return artistCompare;
      return a.albumName.compareTo(b.albumName);
    });

    return groups;
  }

  Future<AlbumGroup?> getAlbumGroupForSong(Song song) async {
    final targetKey = _albumGroupKey(
      _albumNameForSong(song),
      _albumArtistForSong(song),
    );
    final groups = await getAlbumGroups();

    for (final group in groups) {
      if (group.key == targetKey) return group;
    }

    return null;
  }

  /// Get all unique artists with their songs.
  Future<Map<String, List<Song>>> getSongsByArtist() async {
    final songs = await getAllSongs();
    final artistMap = <String, List<Song>>{};
    for (final song in songs) {
      artistMap.putIfAbsent(song.artist, () => []).add(song);
    }
    return artistMap;
  }

  /// Get unique folder URIs from songs.
  Future<List<String>> getUniqueFolderUris() async {
    final entities = await _isar.songEntitys.where().findAll();
    final uris = entities.map((e) => e.folderUri).whereType<String>().toSet();
    return uris.toList();
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
      sampleRate: entity.sampleRate,
      bitDepth: entity.bitDepth,
      album: entity.album,
      albumArtist: entity.albumArtist,
      trackNumber: entity.trackNumber,
      discNumber: entity.discNumber,
      filePath: entity.filePath,
      dateAdded: entity.dateAdded,
    );
  }

  int _compareAlbumSongs(Song a, Song b) {
    final discA = (a.discNumber != null && a.discNumber! > 0)
        ? a.discNumber!
        : 1;
    final discB = (b.discNumber != null && b.discNumber! > 0)
        ? b.discNumber!
        : 1;
    final discCompare = discA.compareTo(discB);
    if (discCompare != 0) return discCompare;

    final trackA = (a.trackNumber != null && a.trackNumber! > 0)
        ? a.trackNumber
        : null;
    final trackB = (b.trackNumber != null && b.trackNumber! > 0)
        ? b.trackNumber
        : null;
    final hasTrackA = trackA != null;
    final hasTrackB = trackB != null;
    if (hasTrackA && hasTrackB) {
      final trackCompare = trackA.compareTo(trackB);
      if (trackCompare != 0) return trackCompare;
    } else if (hasTrackA != hasTrackB) {
      return hasTrackA ? -1 : 1;
    }

    final titleCompare = a.title.compareTo(b.title);
    if (titleCompare != 0) return titleCompare;

    return a.artist.compareTo(b.artist);
  }

  String _albumNameForSong(Song song) {
    final albumName = song.album?.trim();
    if (albumName == null || albumName.isEmpty) {
      return 'Unknown Album';
    }
    return albumName;
  }

  String _albumArtistForSong(Song song) {
    final albumArtist = song.albumArtist?.trim();
    if (albumArtist != null && albumArtist.isNotEmpty) {
      return albumArtist;
    }

    final artist = song.artist.trim();
    if (artist.isNotEmpty) return artist;
    return 'Unknown Artist';
  }

  String _albumGroupKey(String albumName, String albumArtist) {
    return '$albumArtist\u0000$albumName';
  }

  /// Build a resolution string from entity properties.
  String _buildResolutionString(SongEntity entity) {
    final parts = <String>[];
    if (entity.bitDepth != null) {
      parts.add('${entity.bitDepth}-bit');
    }
    if (entity.sampleRate != null) {
      parts.add('${_formatSampleRateKhz(entity.sampleRate!)}kHz');
    }
    if (entity.bitrate != null) {
      final bitrateKbps = (entity.bitrate! / 1000).round();
      parts.add('${bitrateKbps}kbps');
    }
    return parts.isEmpty ? 'Unknown' : parts.join(' / ');
  }

  String _formatSampleRateKhz(int sampleRateHz) {
    final khz = sampleRateHz / 1000;
    if (sampleRateHz % 1000 == 0) {
      return khz.toStringAsFixed(0);
    }
    return khz.toStringAsFixed(1);
  }
}
