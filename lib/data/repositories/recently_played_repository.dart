import 'package:isar_community/isar.dart';

import '../database.dart';
import '../../models/song.dart';
import 'song_repository.dart';

/// Entry representing a recently played song with its timestamp.
class RecentlyPlayedEntry {
  final Song song;
  final DateTime playedAt;

  RecentlyPlayedEntry({required this.song, required this.playedAt});
}

/// Repository for recently played history operations.
class RecentlyPlayedRepository {
  final Isar _isar;
  final SongRepository _songRepository;

  /// Maximum number of history entries to keep
  static const int maxHistoryEntries = 200;

  RecentlyPlayedRepository({Isar? isar, SongRepository? songRepository})
    : _isar = isar ?? Database.instance,
      _songRepository = songRepository ?? SongRepository();

  /// Record a song as played.
  Future<void> recordPlay(String songId) async {
    final id = int.tryParse(songId);
    if (id == null) return;

    await _isar.writeTxn(() async {
      final entity = RecentlyPlayedEntity()
        ..songId = id
        ..playedAt = DateTime.now();

      await _isar.recentlyPlayedEntitys.put(entity);

      // Cleanup old entries if we exceed max
      final count = await _isar.recentlyPlayedEntitys.count();
      if (count > maxHistoryEntries) {
        final toDelete = count - maxHistoryEntries;
        final oldEntries = await _isar.recentlyPlayedEntitys
            .where()
            .sortByPlayedAt()
            .limit(toDelete)
            .findAll();

        await _isar.recentlyPlayedEntitys.deleteAll(
          oldEntries.map((e) => e.id).toList(),
        );
      }
    });
  }

  /// Get recently played songs grouped by time period.
  /// Returns a map with keys like "Today", "Yesterday", "This Week", etc.
  Future<Map<String, List<RecentlyPlayedEntry>>> getGroupedHistory() async {
    final entries = await _isar.recentlyPlayedEntitys
        .where()
        .sortByPlayedAtDesc()
        .findAll();

    if (entries.isEmpty) return {};

    // Get all song entities
    final allSongEntities = await _songRepository.getAllSongEntities();
    final songMap = {for (var e in allSongEntities) e.id: e};

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final thisWeekStart = today.subtract(Duration(days: today.weekday - 1));
    final lastWeekStart = thisWeekStart.subtract(const Duration(days: 7));
    final thisMonthStart = DateTime(now.year, now.month, 1);

    final grouped = <String, List<RecentlyPlayedEntry>>{};

    for (final entry in entries) {
      final songEntity = songMap[entry.songId];
      if (songEntity == null) continue;

      final song = _entityToSong(songEntity);
      final recentEntry = RecentlyPlayedEntry(
        song: song,
        playedAt: entry.playedAt,
      );

      final playedDate = DateTime(
        entry.playedAt.year,
        entry.playedAt.month,
        entry.playedAt.day,
      );

      String groupKey;
      if (playedDate == today) {
        groupKey = 'Today';
      } else if (playedDate == yesterday) {
        groupKey = 'Yesterday';
      } else if (playedDate.isAfter(thisWeekStart) ||
          playedDate == thisWeekStart) {
        groupKey = 'This Week';
      } else if (playedDate.isAfter(lastWeekStart) ||
          playedDate == lastWeekStart) {
        groupKey = 'Last Week';
      } else if (playedDate.isAfter(thisMonthStart) ||
          playedDate == thisMonthStart) {
        groupKey = 'This Month';
      } else {
        groupKey = 'Earlier';
      }

      grouped.putIfAbsent(groupKey, () => []).add(recentEntry);
    }

    return grouped;
  }

  /// Get flat list of recently played entries (most recent first).
  Future<List<RecentlyPlayedEntry>> getRecentHistory({int limit = 50}) async {
    final entries = await _isar.recentlyPlayedEntitys
        .where()
        .sortByPlayedAtDesc()
        .limit(limit)
        .findAll();

    final allSongEntities = await _songRepository.getAllSongEntities();
    final songMap = {for (var e in allSongEntities) e.id: e};

    final result = <RecentlyPlayedEntry>[];
    for (final entry in entries) {
      final songEntity = songMap[entry.songId];
      if (songEntity == null) continue;

      result.add(
        RecentlyPlayedEntry(
          song: _entityToSong(songEntity),
          playedAt: entry.playedAt,
        ),
      );
    }

    return result;
  }

  /// Clear all play history.
  Future<void> clearHistory() async {
    await _isar.writeTxn(() async {
      await _isar.recentlyPlayedEntitys.clear();
    });
  }

  /// Get history count.
  Future<int> getHistoryCount() async {
    return await _isar.recentlyPlayedEntitys.count();
  }

  /// Watch for changes in the history collection.
  Stream<void> watchHistory() {
    return _isar.recentlyPlayedEntitys.watchLazy();
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
      // Convert from bits per second to kilobits per second
      final bitrateKbps = (entity.bitrate! / 1000).round();
      parts.add('${bitrateKbps}kbps');
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
