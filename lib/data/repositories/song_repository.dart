import 'package:isar_community/isar.dart';

import '../../core/utils/audio_metadata_utils.dart';
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
        .where()
        .folderUriEqualTo(folderUri)
        .sortByTitle()
        .findAll();
    return entities.map(_entityToSong).toList();
  }

  /// Get song entities by folder URI (internal use for scanning).
  Future<List<SongEntity>> getSongEntitiesByFolder(String folderUri) async {
    return await _isar.songEntitys
        .where()
        .folderUriEqualTo(folderUri)
        .findAll();
  }

  /// Search songs by title, artist, album, albumArtist or genre.
  Future<List<Song>> searchSongs(String query) async {
    final lowerQuery = query.toLowerCase();
    final entities = await _isar.songEntitys
        .filter()
        .titleContains(lowerQuery, caseSensitive: false)
        .or()
        .artistContains(lowerQuery, caseSensitive: false)
        .or()
        .albumContains(lowerQuery, caseSensitive: false)
        .or()
        .albumArtistContains(lowerQuery, caseSensitive: false)
        .or()
        .genreContains(lowerQuery, caseSensitive: false)
        .sortByTitle()
        .findAll();
    var results = entities.map(_entityToSong).toList();
    // Year is numeric – include songs where the year string contains the query.
    if (lowerQuery.isNotEmpty && RegExp(r'\d').hasMatch(lowerQuery)) {
      final all = await getAllSongs();
      final yearMatches = all.where((s) {
        final y = s.year;
        if (y == null) return false;
        return y.toString().contains(lowerQuery);
      }).toList();
      final seen = results.map((s) => s.id).toSet();
      for (final s in yearMatches) {
        if (!seen.contains(s.id)) results.add(s);
      }
      results.sort((a, b) => a.title.compareTo(b.title));
    }
    // Folder name matches are handled via GlobalSearchResults; kept minimal here.
    return results;
  }

  /// Get song count.
  Future<int> getSongCount() async {
    return await _isar.songEntitys.count();
  }

  /// Get a paginated slice of songs ordered by most recently added.
  /// Backed by the indexed `dateAdded` field (efficient DB-level sort).
  Future<List<Song>> getRecentlyAddedSongs({
    int offset = 0,
    int limit = 50,
  }) async {
    final entities = await _isar.songEntitys
        .where()
        .sortByDateAddedDesc()
        .offset(offset)
        .limit(limit)
        .findAll();
    return entities.map(_entityToSong).toList();
  }

  /// Add or update a song. Matches on composite key (filePath, startOffsetMs).
  Future<void> upsertSong(SongEntity entity) async {
    await _isar.writeTxn(() async {
      final existing = await _isar.songEntitys.getByFilePathStartOffsetMs(
        entity.filePath,
        entity.startOffsetMs,
      );

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
      for (final entity in entities) {
        final existing = await _isar.songEntitys.getByFilePathStartOffsetMs(
          entity.filePath,
          entity.startOffsetMs,
        );
        if (existing != null) {
          entity.id = existing.id;
        }
      }
      await _isar.songEntitys.putAll(entities);
    });
  }

  /// Persist ReplayGain metadata for a path (written by the ReplayGain
  /// scanner, which keeps the DB in sync with the file tags). Applies to
  /// every entity sharing the path (CUE tracks included).
  Future<void> updateReplayGainForPath(
    String filePath, {
    required double? trackGainDb,
    required double? trackPeak,
    required double? albumGainDb,
    required double? albumPeak,
  }) async {
    if (filePath.isEmpty) return;

    await _isar.writeTxn(() async {
      final entities = await _isar.songEntitys
          .where()
          .filePathEqualToAnyStartOffsetMs(filePath)
          .findAll();

      for (final entity in entities) {
        entity
          ..replaygainTrackGain = trackGainDb
          ..replaygainTrackPeak = trackPeak
          ..replaygainAlbumGain = albumGainDb
          ..replaygainAlbumPeak = albumPeak;
      }
      if (entities.isNotEmpty) {
        await _isar.songEntitys.putAll(entities);
      }
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
      await _isar.songEntitys.where().folderUriEqualTo(folderUri).deleteAll();
    });
  }

  /// All songs synced from a network server (used by network sync purge).
  Future<List<SongEntity>> getSongsByRemoteServer(int remoteServerId) async {
    return await _isar.songEntitys
        .where()
        .remoteServerIdEqualTo(remoteServerId)
        .findAll();
  }

  /// Count songs synced from a network server (cheaper than fetching).
  Future<int> countSongsByRemoteServer(int remoteServerId) async {
    return await _isar.songEntitys
        .where()
        .remoteServerIdEqualTo(remoteServerId)
        .count();
  }

  /// Delete all songs synced from a network server.
  Future<void> deleteSongsForRemoteServer(int remoteServerId) async {
    await _isar.writeTxn(() async {
      await _isar.songEntitys
          .where()
          .remoteServerIdEqualTo(remoteServerId)
          .deleteAll();
    });
  }

  /// Get all song entities (internal use)
  Future<List<SongEntity>> getAllSongEntities() async {
    return await _isar.songEntitys.where().findAll();
  }

  /// Delete songs by their file paths.
  Future<void> deleteSongsByPath(List<String> paths) async {
    final uniquePaths = paths.where((path) => path.isNotEmpty).toSet();
    if (uniquePaths.isEmpty) return;

    await _isar.writeTxn(() async {
      for (final path in uniquePaths) {
        await _isar.songEntitys
            .where()
            .filePathEqualToAnyStartOffsetMs(path)
            .deleteAll();
      }
    });
  }

  /// Delete raw (non-CUE) songs by file path.
  Future<void> deleteRawSongsByPath(List<String> paths) async {
    final uniquePaths = paths.where((path) => path.isNotEmpty).toList();
    if (uniquePaths.isEmpty) return;

    await _isar.writeTxn(() async {
      await _isar.songEntitys.deleteAllByFilePathStartOffsetMs(
        uniquePaths,
        List<int?>.filled(uniquePaths.length, null),
      );
    });
  }

  /// Delete CUE track songs by file path.
  Future<void> deleteCueTracksByPath(List<String> paths) async {
    final uniquePaths = paths.where((path) => path.isNotEmpty).toSet();
    if (uniquePaths.isEmpty) return;

    await _isar.writeTxn(() async {
      for (final path in uniquePaths) {
        await _isar.songEntitys
            .where()
            .filePathEqualToAnyStartOffsetMs(path)
            .filter()
            .startOffsetMsIsNotNull()
            .deleteAll();
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

  Future<void> updateAlbumArtPaths(
    Iterable<String> filePaths,
    String? albumArtPath,
  ) async {
    final uniquePaths = filePaths.where((path) => path.isNotEmpty).toSet();
    if (uniquePaths.isEmpty) {
      return;
    }

    await _isar.writeTxn(() async {
      for (final filePath in uniquePaths) {
        final existing = await _isar.songEntitys
            .filter()
            .filePathEqualTo(filePath)
            .findFirst();
        if (existing == null || existing.albumArtPath == albumArtPath) {
          continue;
        }

        existing.albumArtPath = albumArtPath;
        await _isar.songEntitys.put(existing);
      }
    });
  }

  Future<Set<String>> getReferencedAlbumArtPaths() async {
    final paths =
        await _isar.songEntitys.where().albumArtPathProperty().findAll();
    return paths.whereType<String>().where((p) => p.isNotEmpty).toSet();
  }

  Future<void> updateSongMetadata(
    String filePath, {
    String? title,
    String? artist,
    String? album,
    String? albumArtist,
    int? trackNumber,
    int? discNumber,
    int? year,
    String? genre,
  }) async {
    await _isar.writeTxn(() async {
      final existing = await _isar.songEntitys
          .filter()
          .filePathEqualTo(filePath)
          .findFirst();
      if (existing == null) return;

      if (title != null) existing.title = title;
      if (artist != null) existing.artist = artist;
      if (album != null) existing.album = album;
      if (albumArtist != null) existing.albumArtist = albumArtist;
      if (trackNumber != null) existing.trackNumber = trackNumber;
      if (discNumber != null) existing.discNumber = discNumber;
      if (year != null) existing.year = year;
      if (genre != null) existing.genre = genre;
      existing.hasLocalEdits = true;

      await _isar.songEntitys.put(existing);
    });
  }

  /// Persist probed audio format for songs whose sync couldn't read tags
  /// (SMB/WebDAV). Only fills null fields.
  Future<void> updateAudioFormat(
    String filePath, {
    int? sampleRate,
    int? bitDepth,
  }) async {
    await _isar.writeTxn(() async {
      final existing = await _isar.songEntitys
          .filter()
          .filePathEqualTo(filePath)
          .findFirst();
      if (existing == null) return;
      var changed = false;
      if (sampleRate != null && existing.sampleRate == null) {
        existing.sampleRate = sampleRate;
        changed = true;
      }
      if (bitDepth != null && existing.bitDepth == null) {
        existing.bitDepth = bitDepth;
        changed = true;
      }
      if (changed) await _isar.songEntitys.put(existing);
    });
  }

  /// Count songs in a folder.
  Future<int> countSongsInFolder(String folderUri) async {
    return await _isar.songEntitys.where().folderUriEqualTo(folderUri).count();
  }

  Future<List<SongEntity>> getIncompleteMetadataSongs() async {
    return await _isar.songEntitys
        .where()
        .metadataCompleteEqualTo(false)
        .findAll();
  }

  /// Count songs still awaiting background metadata extraction.
  /// Cheaper than [getIncompleteMetadataSongs] (no entity deserialization);
  /// uses the metadataComplete index.
  Future<int> countIncompleteMetadataSongs() async {
    return await _isar.songEntitys
        .where()
        .metadataCompleteEqualTo(false)
        .count();
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
      albumSongs.sort(SongRepository._compareAlbumSongs);
    }
    return albumMap;
  }

  Future<List<AlbumGroup>> getAlbumGroups() async {
    final songs = await getAllSongs();
    final groupedSongs = <String, List<Song>>{};
    final albumNames = <String, String>{};
    final albumArtistsByKey = <String, Set<String>>{};

    for (final song in songs) {
      final albumName = _albumNameForSong(song);
      final albumArtist = albumArtistForSong(song);
      final key = _albumGroupKey(albumName);

      groupedSongs.putIfAbsent(key, () => []).add(song);
      albumNames[key] = albumName;
      albumArtistsByKey.putIfAbsent(key, () => <String>{}).add(albumArtist);
    }

    final groups = groupedSongs.entries.map((entry) {
      final songs = List<Song>.from(entry.value)
        ..sort(SongRepository._compareAlbumSongs);
      return AlbumGroup(
        key: entry.key,
        albumName: albumNames[entry.key] ?? 'Unknown Album',
        albumArtist: resolveGroupArtist(
          albumArtistsByKey[entry.key] ?? const {},
        ),
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
    final targetKey = _albumGroupKey(_albumNameForSong(song));
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
    for (final entry in artistMap.entries) {
      artistMap[entry.key] = SongRepository.sortSongsByAlbum(entry.value);
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
      replaygainTrackGain: entity.replaygainTrackGain,
      replaygainTrackPeak: entity.replaygainTrackPeak,
      replaygainAlbumGain: entity.replaygainAlbumGain,
      replaygainAlbumPeak: entity.replaygainAlbumPeak,
      startOffsetMs: entity.startOffsetMs,
      endOffsetMs: entity.endOffsetMs,
      ripper: entity.ripper,
      readMode: entity.readMode,
      accurateRip: entity.accurateRip,
      testCrc: entity.testCrc,
      copyCrc: entity.copyCrc,
      album: entity.album,
      albumArtist: entity.albumArtist,
      trackNumber: entity.trackNumber,
      discNumber: entity.discNumber,
      year: entity.year,
      genre: entity.genre,
      filePath: entity.filePath,
      folderUri: entity.folderUri,
      dateAdded: entity.dateAdded,
      sourceType: entity.sourceType,
      remoteId: entity.remoteId,
      remoteServerId: entity.remoteServerId,
    );
  }

  /// Sort songs by album grouping, with tracks sorted by disc/track number.
  /// Albums are sorted alphabetically; within each album, tracks are sorted
  /// by disc number, then track number, then title.
  static List<Song> sortSongsByAlbum(List<Song> songs) {
    final albumMap = <String, List<Song>>{};
    for (final song in songs) {
      final albumName = _albumNameFor(song);
      albumMap.putIfAbsent(albumName, () => []).add(song);
    }
    final sorted = <Song>[];
    final albumNames = albumMap.keys.toList()..sort();
    for (final albumName in albumNames) {
      final albumSongs = albumMap[albumName]!;
      albumSongs.sort(SongRepository._compareAlbumSongs);
      sorted.addAll(albumSongs);
    }
    return sorted;
  }

  static String _albumNameFor(Song song) {
    final album = song.album?.trim() ?? '';
    return album.isEmpty ? 'Unknown Album' : album;
  }

  static int _compareAlbumSongs(Song a, Song b) {
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

  static bool _isVariousArtistsTag(String value) =>
      value.toLowerCase() == 'various artists';

  static String albumArtistForSong(Song song) {
    final albumArtist = song.albumArtist?.trim();
    if (albumArtist != null && albumArtist.isNotEmpty) {
      // A literal "Various Artists" albumartist tag is a placeholder, not a
      // name; prefer the per-track artist so real names surface.
      if (_isVariousArtistsTag(albumArtist)) {
        final artist = song.artist.trim();
        if (artist.isNotEmpty && !_isVariousArtistsTag(artist)) return artist;
      }
      return albumArtist;
    }

    final artist = song.artist.trim();
    if (artist.isNotEmpty) return artist;
    return 'Unknown Artist';
  }

  // ponytail: >1 distinct albumArtist ⇒ untagged compilation (scanner bakes
  // per-track artist in when the tag's missing). Show the actual names
  // comma-joined; only an explicit "Various Artists" tag collapses to itself.
  // Ceiling: a regular album with a few mistagged tracks shows a noisy
  // artist list; upgrade to grouping by MediaStore ALBUM_ID if that bites.
  static String resolveGroupArtist(Set<String> artists) {
    final distinct = artists
        .map((a) => a.trim())
        .where((a) => a.isNotEmpty)
        .toSet();
    if (distinct.length > 1) {
      if (distinct.contains('Various Artists')) return 'Various Artists';
      return (distinct.toList()..sort()).join(', ');
    }
    if (distinct.length == 1) return distinct.first;
    return 'Unknown Artist';
  }

  String _albumGroupKey(String albumName) {
    return albumName;
  }

  /// Build a resolution string from entity properties. Null when the source
  /// sync had no audio metrics (SMB/WebDAV) — callers hide the chip instead
  /// of showing a placeholder.
  String? _buildResolutionString(SongEntity entity) {
    final parts = <String>[];
    if (entity.bitDepth != null) {
      parts.add('${entity.bitDepth}-bit');
    }
    if (entity.sampleRate != null) {
      parts.add('${_formatSampleRateKhz(entity.sampleRate!)}kHz');
    }
    final bitrateLabel = AudioMetadataUtils.formatBitrateLabel(
      entity.bitrate,
      sampleRate: entity.sampleRate,
      bitDepth: entity.bitDepth,
    );
    if (bitrateLabel != null) {
      parts.add(bitrateLabel);
    }
    return parts.isEmpty ? null : parts.join(' / ');
  }

  String _formatSampleRateKhz(int sampleRateHz) {
    final khz = sampleRateHz / 1000;
    if (sampleRateHz % 1000 == 0) {
      return khz.toStringAsFixed(0);
    }
    return khz.toStringAsFixed(1);
  }

  // --- Audio cache (preload scan) ---

  Future<SongAudioCacheEntity?> getAudioCache(int songId) async {
    return await _isar.songAudioCacheEntitys
        .where()
        .songIdEqualTo(songId)
        .findFirst();
  }

  Future<Map<int, SongAudioCacheEntity>> getAudioCacheMap(
    Iterable<int> songIds,
  ) async {
    final ids = songIds.toSet();
    if (ids.isEmpty) return {};
    final rows = await _isar.songAudioCacheEntitys
        .where()
        .anyOf(ids.toList(), (q, id) => q.songIdEqualTo(id))
        .findAll();
    return {for (final r in rows) r.songId: r};
  }

  Future<void> upsertAudioCache(SongAudioCacheEntity entity) async {
    await _isar.writeTxn(() async {
      await _isar.songAudioCacheEntitys.put(entity);
    });
  }

  Future<void> upsertAudioCacheBatch(
    List<SongAudioCacheEntity> entities,
  ) async {
    if (entities.isEmpty) return;
    await _isar.writeTxn(() async {
      await _isar.songAudioCacheEntitys.putAll(entities);
    });
  }

  Future<void> deleteAudioCacheBySongIds(List<int> songIds) async {
    if (songIds.isEmpty) return;
    await _isar.writeTxn(() async {
      await _isar.songAudioCacheEntitys.deleteAll(songIds);
    });
  }

  Future<void> clearAllAudioCache() async {
    await _isar.writeTxn(() async {
      await _isar.songAudioCacheEntitys.clear();
    });
  }
}
