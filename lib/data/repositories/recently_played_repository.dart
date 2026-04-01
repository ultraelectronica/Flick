import 'package:isar_community/isar.dart';

import '../../core/utils/audio_metadata_utils.dart';
import '../database.dart';
import '../../models/song.dart';
import 'song_repository.dart';

enum ListeningRecapPeriod { daily, weekly, monthly, yearly }

extension ListeningRecapPeriodX on ListeningRecapPeriod {
  String get label {
    return switch (this) {
      ListeningRecapPeriod.daily => 'Daily',
      ListeningRecapPeriod.weekly => 'Weekly',
      ListeningRecapPeriod.monthly => 'Monthly',
      ListeningRecapPeriod.yearly => 'Yearly',
    };
  }

  String get title {
    return switch (this) {
      ListeningRecapPeriod.daily => 'Today\'s Recap',
      ListeningRecapPeriod.weekly => 'This Week\'s Recap',
      ListeningRecapPeriod.monthly => 'This Month\'s Recap',
      ListeningRecapPeriod.yearly => 'This Year\'s Recap',
    };
  }

  String get emptyMessage {
    return switch (this) {
      ListeningRecapPeriod.daily =>
        'Play a few tracks today to build your daily recap.',
      ListeningRecapPeriod.weekly =>
        'Your weekly recap appears once you start listening this week.',
      ListeningRecapPeriod.monthly =>
        'Your monthly recap needs a bit more listening time this month.',
      ListeningRecapPeriod.yearly =>
        'Your yearly recap fills in as you keep listening throughout the year.',
    };
  }

  ListeningRecapRange rangeFor(DateTime anchor) {
    final normalizedAnchor = DateTime(anchor.year, anchor.month, anchor.day);

    return switch (this) {
      ListeningRecapPeriod.daily => ListeningRecapRange(
        start: normalizedAnchor,
        endExclusive: normalizedAnchor.add(const Duration(days: 1)),
      ),
      ListeningRecapPeriod.weekly => () {
        final start = normalizedAnchor.subtract(
          Duration(days: normalizedAnchor.weekday - 1),
        );
        return ListeningRecapRange(
          start: start,
          endExclusive: start.add(const Duration(days: 7)),
        );
      }(),
      ListeningRecapPeriod.monthly => ListeningRecapRange(
        start: DateTime(anchor.year, anchor.month),
        endExclusive: anchor.month == 12
            ? DateTime(anchor.year + 1, 1)
            : DateTime(anchor.year, anchor.month + 1),
      ),
      ListeningRecapPeriod.yearly => ListeningRecapRange(
        start: DateTime(anchor.year),
        endExclusive: DateTime(anchor.year + 1),
      ),
    };
  }
}

class ListeningRecapRange {
  final DateTime start;
  final DateTime endExclusive;

  const ListeningRecapRange({required this.start, required this.endExclusive});
}

class RankedRecapSong {
  final Song song;
  final int plays;
  final Duration listeningTime;
  final DateTime lastPlayedAt;

  const RankedRecapSong({
    required this.song,
    required this.plays,
    required this.listeningTime,
    required this.lastPlayedAt,
  });
}

class RankedRecapArtist {
  final String artist;
  final int plays;
  final int uniqueSongs;
  final Duration listeningTime;
  final DateTime lastPlayedAt;

  const RankedRecapArtist({
    required this.artist,
    required this.plays,
    required this.uniqueSongs,
    required this.listeningTime,
    required this.lastPlayedAt,
  });
}

class RankedRecapAlbum {
  final String album;
  final String artist;
  final int plays;
  final int uniqueSongs;
  final Duration listeningTime;
  final DateTime lastPlayedAt;
  final Song representativeSong;

  const RankedRecapAlbum({
    required this.album,
    required this.artist,
    required this.plays,
    required this.uniqueSongs,
    required this.listeningTime,
    required this.lastPlayedAt,
    required this.representativeSong,
  });
}

class ListeningRecap {
  final ListeningRecapPeriod period;
  final DateTime start;
  final DateTime endExclusive;
  final int totalPlays;
  final Duration totalListeningTime;
  final int uniqueSongs;
  final int uniqueArtists;
  final int activeDays;
  final int? peakHour;
  final RankedRecapSong? topSong;
  final RankedRecapArtist? topArtist;
  final RankedRecapAlbum? topAlbum;
  final List<RankedRecapSong> topSongs;
  final List<RankedRecapArtist> topArtists;
  final List<RankedRecapAlbum> topAlbums;

  const ListeningRecap({
    required this.period,
    required this.start,
    required this.endExclusive,
    required this.totalPlays,
    required this.totalListeningTime,
    required this.uniqueSongs,
    required this.uniqueArtists,
    required this.activeDays,
    required this.peakHour,
    required this.topSong,
    required this.topArtist,
    required this.topAlbum,
    required this.topSongs,
    required this.topArtists,
    required this.topAlbums,
  });

  factory ListeningRecap.empty(
    ListeningRecapPeriod period,
    ListeningRecapRange range,
  ) {
    return ListeningRecap(
      period: period,
      start: range.start,
      endExclusive: range.endExclusive,
      totalPlays: 0,
      totalListeningTime: Duration.zero,
      uniqueSongs: 0,
      uniqueArtists: 0,
      activeDays: 0,
      peakHour: null,
      topSong: null,
      topArtist: null,
      topAlbum: null,
      topSongs: const [],
      topArtists: const [],
      topAlbums: const [],
    );
  }

  bool get hasData => totalPlays > 0;
}

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
  static const int maxHistoryEntries = 50000;

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

  /// Build Wrapped-style recaps for the current day, week, month, and year.
  Future<Map<ListeningRecapPeriod, ListeningRecap>> getListeningRecaps({
    Iterable<ListeningRecapPeriod>? periods,
    DateTime? now,
  }) async {
    final resolvedPeriods = (periods ?? ListeningRecapPeriod.values).toList();
    if (resolvedPeriods.isEmpty) {
      return const {};
    }

    final anchor = now ?? DateTime.now();
    final ranges = {
      for (final period in resolvedPeriods) period: period.rangeFor(anchor),
    };

    final earliestStart = ranges.values
        .map((range) => range.start)
        .reduce((current, next) => current.isBefore(next) ? current : next);
    final latestEndExclusive = ranges.values
        .map((range) => range.endExclusive)
        .reduce((current, next) => current.isAfter(next) ? current : next);

    final mappedEntries = await _getEntriesBetween(
      start: earliestStart,
      endExclusive: latestEndExclusive,
    );

    return {
      for (final period in resolvedPeriods)
        period: _buildListeningRecap(
          period: period,
          range: ranges[period]!,
          entries: mappedEntries.where((entry) {
            return !entry.playedAt.isBefore(ranges[period]!.start) &&
                entry.playedAt.isBefore(ranges[period]!.endExclusive);
          }).toList(),
        ),
    };
  }

  /// Build a Wrapped-style recap for a single period.
  Future<ListeningRecap> getListeningRecap(
    ListeningRecapPeriod period, {
    DateTime? now,
  }) async {
    final recaps = await getListeningRecaps(periods: [period], now: now);
    return recaps[period]!;
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

  Future<List<RecentlyPlayedEntry>> _getEntriesBetween({
    required DateTime start,
    required DateTime endExclusive,
  }) async {
    final entries = await _isar.recentlyPlayedEntitys
        .where()
        .playedAtBetween(start, endExclusive, includeUpper: false)
        .sortByPlayedAtDesc()
        .findAll();

    if (entries.isEmpty) {
      return const [];
    }

    final allSongEntities = await _songRepository.getAllSongEntities();
    final songMap = {for (final entity in allSongEntities) entity.id: entity};

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

  ListeningRecap _buildListeningRecap({
    required ListeningRecapPeriod period,
    required ListeningRecapRange range,
    required List<RecentlyPlayedEntry> entries,
  }) {
    if (entries.isEmpty) {
      return ListeningRecap.empty(period, range);
    }

    final songStats = <String, _SongRecapAccumulator>{};
    final artistStats = <String, _ArtistRecapAccumulator>{};
    final albumStats = <String, _AlbumRecapAccumulator>{};
    final playedDays = <DateTime>{};
    final hourStats = <int, int>{};

    var totalListeningTime = Duration.zero;

    for (final entry in entries) {
      final song = entry.song;
      totalListeningTime += song.duration;

      final songAccumulator = songStats.putIfAbsent(
        song.id,
        () => _SongRecapAccumulator(song),
      );
      songAccumulator.addPlay(entry.playedAt);

      final artistKey = song.artist.trim().isEmpty
          ? 'Unknown Artist'
          : song.artist.trim();
      final artistAccumulator = artistStats.putIfAbsent(
        artistKey,
        () => _ArtistRecapAccumulator(artistKey),
      );
      artistAccumulator.addPlay(song, entry.playedAt);

      final albumName = (song.album?.trim().isNotEmpty ?? false)
          ? song.album!.trim()
          : 'Unknown Album';
      final albumArtist = (song.albumArtist?.trim().isNotEmpty ?? false)
          ? song.albumArtist!.trim()
          : artistKey;
      final albumKey = '$albumArtist::$albumName';
      final albumAccumulator = albumStats.putIfAbsent(
        albumKey,
        () => _AlbumRecapAccumulator(albumName, albumArtist, song),
      );
      albumAccumulator.addPlay(song, entry.playedAt);

      playedDays.add(
        DateTime(entry.playedAt.year, entry.playedAt.month, entry.playedAt.day),
      );
      hourStats.update(
        entry.playedAt.hour,
        (count) => count + 1,
        ifAbsent: () {
          return 1;
        },
      );
    }

    final rankedSongs = songStats.values.map((item) => item.toRanked()).toList()
      ..sort(_compareRankedSongs);
    final rankedArtists =
        artistStats.values.map((item) => item.toRanked()).toList()
          ..sort(_compareRankedArtists);
    final rankedAlbums =
        albumStats.values.map((item) => item.toRanked()).toList()
          ..sort(_compareRankedAlbums);
    final peakHour = _findPeakHour(hourStats);

    return ListeningRecap(
      period: period,
      start: range.start,
      endExclusive: range.endExclusive,
      totalPlays: entries.length,
      totalListeningTime: totalListeningTime,
      uniqueSongs: songStats.length,
      uniqueArtists: artistStats.length,
      activeDays: playedDays.length,
      peakHour: peakHour,
      topSong: rankedSongs.isEmpty ? null : rankedSongs.first,
      topArtist: rankedArtists.isEmpty ? null : rankedArtists.first,
      topAlbum: rankedAlbums.isEmpty ? null : rankedAlbums.first,
      topSongs: rankedSongs.take(5).toList(),
      topArtists: rankedArtists.take(5).toList(),
      topAlbums: rankedAlbums.take(3).toList(),
    );
  }

  int? _findPeakHour(Map<int, int> hourStats) {
    if (hourStats.isEmpty) return null;

    final rankedHours = hourStats.entries.toList()
      ..sort((left, right) {
        final playCompare = right.value.compareTo(left.value);
        if (playCompare != 0) return playCompare;
        return left.key.compareTo(right.key);
      });
    return rankedHours.first.key;
  }

  int _compareRankedSongs(RankedRecapSong left, RankedRecapSong right) {
    final playCompare = right.plays.compareTo(left.plays);
    if (playCompare != 0) return playCompare;

    final timeCompare = right.listeningTime.inMilliseconds.compareTo(
      left.listeningTime.inMilliseconds,
    );
    if (timeCompare != 0) return timeCompare;

    final recentCompare = right.lastPlayedAt.compareTo(left.lastPlayedAt);
    if (recentCompare != 0) return recentCompare;

    return left.song.title.compareTo(right.song.title);
  }

  int _compareRankedArtists(RankedRecapArtist left, RankedRecapArtist right) {
    final playCompare = right.plays.compareTo(left.plays);
    if (playCompare != 0) return playCompare;

    final timeCompare = right.listeningTime.inMilliseconds.compareTo(
      left.listeningTime.inMilliseconds,
    );
    if (timeCompare != 0) return timeCompare;

    final recentCompare = right.lastPlayedAt.compareTo(left.lastPlayedAt);
    if (recentCompare != 0) return recentCompare;

    return left.artist.compareTo(right.artist);
  }

  int _compareRankedAlbums(RankedRecapAlbum left, RankedRecapAlbum right) {
    final playCompare = right.plays.compareTo(left.plays);
    if (playCompare != 0) return playCompare;

    final timeCompare = right.listeningTime.inMilliseconds.compareTo(
      left.listeningTime.inMilliseconds,
    );
    if (timeCompare != 0) return timeCompare;

    final recentCompare = right.lastPlayedAt.compareTo(left.lastPlayedAt);
    if (recentCompare != 0) return recentCompare;

    final albumCompare = left.album.compareTo(right.album);
    if (albumCompare != 0) return albumCompare;

    return left.artist.compareTo(right.artist);
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
      filePath: entity.filePath,
      dateAdded: entity.dateAdded,
    );
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
    final bitrateLabel = AudioMetadataUtils.formatBitrateLabel(
      entity.bitrate,
      sampleRate: entity.sampleRate,
      bitDepth: entity.bitDepth,
    );
    if (bitrateLabel != null) {
      parts.add(bitrateLabel);
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

class _SongRecapAccumulator {
  final Song song;
  int plays = 0;
  Duration listeningTime = Duration.zero;
  DateTime? lastPlayedAt;

  _SongRecapAccumulator(this.song);

  void addPlay(DateTime playedAt) {
    plays += 1;
    listeningTime += song.duration;
    if (lastPlayedAt == null || playedAt.isAfter(lastPlayedAt!)) {
      lastPlayedAt = playedAt;
    }
  }

  RankedRecapSong toRanked() {
    return RankedRecapSong(
      song: song,
      plays: plays,
      listeningTime: listeningTime,
      lastPlayedAt: lastPlayedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

class _ArtistRecapAccumulator {
  final String artist;
  final Set<String> uniqueSongIds = <String>{};
  int plays = 0;
  Duration listeningTime = Duration.zero;
  DateTime? lastPlayedAt;

  _ArtistRecapAccumulator(this.artist);

  void addPlay(Song song, DateTime playedAt) {
    plays += 1;
    listeningTime += song.duration;
    uniqueSongIds.add(song.id);
    if (lastPlayedAt == null || playedAt.isAfter(lastPlayedAt!)) {
      lastPlayedAt = playedAt;
    }
  }

  RankedRecapArtist toRanked() {
    return RankedRecapArtist(
      artist: artist,
      plays: plays,
      uniqueSongs: uniqueSongIds.length,
      listeningTime: listeningTime,
      lastPlayedAt: lastPlayedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

class _AlbumRecapAccumulator {
  final String album;
  final String artist;
  final Set<String> uniqueSongIds = <String>{};
  Song representativeSong;
  int plays = 0;
  Duration listeningTime = Duration.zero;
  DateTime? lastPlayedAt;

  _AlbumRecapAccumulator(this.album, this.artist, this.representativeSong);

  void addPlay(Song song, DateTime playedAt) {
    plays += 1;
    listeningTime += song.duration;
    uniqueSongIds.add(song.id);
    if ((representativeSong.albumArt == null ||
            representativeSong.albumArt!.isEmpty) &&
        song.albumArt != null &&
        song.albumArt!.isNotEmpty) {
      representativeSong = song;
    }
    if (lastPlayedAt == null || playedAt.isAfter(lastPlayedAt!)) {
      lastPlayedAt = playedAt;
    }
  }

  RankedRecapAlbum toRanked() {
    return RankedRecapAlbum(
      album: album,
      artist: artist,
      plays: plays,
      uniqueSongs: uniqueSongIds.length,
      listeningTime: listeningTime,
      lastPlayedAt: lastPlayedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
      representativeSong: representativeSong,
    );
  }
}
