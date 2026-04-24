import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../data/repositories/song_repository.dart';
import '../models/song.dart';

class AlbumArtImportException implements Exception {
  const AlbumArtImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AlbumArtCandidate {
  const AlbumArtCandidate({
    required this.previewUrl,
    required this.imageUrl,
    required this.title,
    required this.artist,
    required this.sourceLabel,
    this.releaseDate,
  });

  final String previewUrl;
  final String imageUrl;
  final String title;
  final String artist;
  final String sourceLabel;
  final String? releaseDate;
}

class AlbumArtUpdateResult {
  const AlbumArtUpdateResult({
    required this.albumName,
    required this.albumArtist,
    required this.albumArtPath,
    required this.filePaths,
  });

  final String albumName;
  final String albumArtist;
  final String? albumArtPath;
  final List<String> filePaths;
}

class AlbumArtImportService {
  AlbumArtImportService._({SongRepository? songRepository, http.Client? client})
    : _songRepository = songRepository ?? SongRepository(),
      _client = client ?? http.Client();

  static final AlbumArtImportService instance = AlbumArtImportService._();
  static const String _customArtworkDirectoryName = 'album_art_overrides';
  static const Duration _requestTimeout = Duration(seconds: 12);
  static const String _musicBrainzHost = 'musicbrainz.org';
  static const String _coverArtHost = 'coverartarchive.org';

  final SongRepository _songRepository;
  final http.Client _client;

  bool isCustomArtworkPath(String? path) {
    if (path == null || path.isEmpty) {
      return false;
    }

    final normalized = path.replaceAll('\\', '/');
    return normalized.contains('/$_customArtworkDirectoryName/');
  }

  Future<List<AlbumArtCandidate>> searchOnlineCandidates(Song song) async {
    final album = _searchAlbumName(song);
    if (album == null) {
      return const [];
    }

    final artist = _searchArtistName(song);
    final candidates = <AlbumArtCandidate>[];
    Object? lastError;

    try {
      candidates.addAll(
        await _searchCoverArtArchive(
          entityType: 'release-group',
          titleField: 'releasegroup',
          album: album,
          artist: artist,
        ),
      );
    } catch (error) {
      lastError = error;
    }

    if (candidates.length < 8) {
      try {
        candidates.addAll(
          await _searchCoverArtArchive(
            entityType: 'release',
            titleField: 'release',
            album: album,
            artist: artist,
          ),
        );
      } catch (error) {
        lastError ??= error;
      }
    }

    final deduped = _dedupeCandidates(candidates);
    if (deduped.isEmpty && lastError != null) {
      throw _asImportException(lastError);
    }

    return deduped;
  }

  Future<AlbumArtUpdateResult> applyOnlineCandidate({
    required Song song,
    required AlbumArtCandidate candidate,
  }) async {
    final response = await _client
        .get(Uri.parse(candidate.imageUrl), headers: _downloadHeaders())
        .timeout(_requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AlbumArtImportException(
        'Failed to download album art (HTTP ${response.statusCode}).',
      );
    }

    return applyImageBytes(song: song, bytes: response.bodyBytes);
  }

  Future<AlbumArtUpdateResult> applyImageBytes({
    required Song song,
    required Uint8List bytes,
  }) async {
    if (!_looksLikeImage(bytes)) {
      throw const AlbumArtImportException(
        'Selected file is not a supported image.',
      );
    }

    final group = await _resolveAlbumGroup(song);
    final filePaths = _albumFilePaths(group);
    final file = await _writeCustomArtwork(group.key, bytes);

    await _songRepository.updateAlbumArtPaths(filePaths, file.path);

    return AlbumArtUpdateResult(
      albumName: group.albumName,
      albumArtist: group.albumArtist,
      albumArtPath: file.path,
      filePaths: filePaths,
    );
  }

  Future<AlbumArtUpdateResult> removeCustomArtwork(Song song) async {
    final group = await _resolveAlbumGroup(song);
    final filePaths = _albumFilePaths(group);
    final customPaths = group.songs
        .map((entry) => entry.albumArt)
        .whereType<String>()
        .where(isCustomArtworkPath)
        .toSet();

    if (customPaths.isEmpty) {
      throw const AlbumArtImportException('No custom album art is set yet.');
    }

    await _songRepository.updateAlbumArtPaths(filePaths, null);

    for (final path in customPaths) {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {
        // Best effort cleanup.
      }
    }

    return AlbumArtUpdateResult(
      albumName: group.albumName,
      albumArtist: group.albumArtist,
      albumArtPath: null,
      filePaths: filePaths,
    );
  }

  Future<List<AlbumArtCandidate>> _searchCoverArtArchive({
    required String entityType,
    required String titleField,
    required String album,
    required String artist,
  }) async {
    final matches = await _searchMusicBrainz(
      entityType: entityType,
      titleField: titleField,
      album: album,
      artist: artist,
    );
    if (matches.isEmpty) {
      return const [];
    }

    final results = await Future.wait(
      matches.take(4).map(_loadCoverArtCandidatesForMatch),
    );

    return results.expand((items) => items).toList();
  }

  Future<List<_MusicBrainzMatch>> _searchMusicBrainz({
    required String entityType,
    required String titleField,
    required String album,
    required String artist,
  }) async {
    final query = _buildMusicBrainzQuery(
      titleField: titleField,
      album: album,
      artist: artist,
    );
    final response = await _getJson(
      Uri.https(_musicBrainzHost, '/ws/2/$entityType', {
        'query': query,
        'fmt': 'json',
        'limit': '8',
      }),
    );

    final listKey = entityType == 'release-group'
        ? 'release-groups'
        : 'releases';
    final entries = response[listKey];
    if (entries is! List) {
      return const [];
    }

    final matches = <_MusicBrainzMatch>[];
    for (final entry in entries) {
      if (entry is! Map<String, dynamic>) {
        continue;
      }

      final id = (entry['id'] as String?)?.trim();
      final title = (entry['title'] as String?)?.trim();
      if (id == null || id.isEmpty || title == null || title.isEmpty) {
        continue;
      }

      final resultArtist = _artistCreditLabel(entry['artist-credit']);
      final releaseDate =
          ((entry['first-release-date'] ?? entry['date']) as String?)?.trim();
      final primaryType = (entry['primary-type'] as String?)?.trim();
      final score = _matchScore(
        title: title,
        artist: resultArtist,
        album: album,
        expectedArtist: artist,
        primaryType: primaryType,
      );

      matches.add(
        _MusicBrainzMatch(
          id: id,
          entityType: entityType,
          title: title,
          artist: resultArtist,
          releaseDate: releaseDate,
          score: score,
        ),
      );
    }

    matches.sort((a, b) {
      final scoreCompare = b.score.compareTo(a.score);
      if (scoreCompare != 0) {
        return scoreCompare;
      }
      return a.title.compareTo(b.title);
    });

    return matches;
  }

  Future<List<AlbumArtCandidate>> _loadCoverArtCandidatesForMatch(
    _MusicBrainzMatch match,
  ) async {
    try {
      final response = await _getJson(
        Uri.https(_coverArtHost, '/${match.entityType}/${match.id}'),
      );
      final images = response['images'];
      if (images is! List || images.isEmpty) {
        return const [];
      }

      final frontImages = images.whereType<Map<String, dynamic>>().where((
        image,
      ) {
        return image['front'] == true;
      }).toList();
      final preferredImages = frontImages.isNotEmpty
          ? frontImages
          : images.whereType<Map<String, dynamic>>().take(1).toList();

      final candidates = <AlbumArtCandidate>[];
      for (final image in preferredImages.take(2)) {
        final imageUrl = (image['image'] as String?)?.trim();
        if (imageUrl == null || imageUrl.isEmpty) {
          continue;
        }

        final thumbnails = image['thumbnails'];
        final previewUrl = thumbnails is Map<String, dynamic>
            ? ((thumbnails['500'] ?? thumbnails['250']) as String?)?.trim() ??
                  imageUrl
            : imageUrl;

        candidates.add(
          AlbumArtCandidate(
            previewUrl: previewUrl,
            imageUrl: imageUrl,
            title: match.title,
            artist: match.artist,
            sourceLabel: match.entityType == 'release-group'
                ? 'MusicBrainz release group'
                : 'MusicBrainz release',
            releaseDate: match.releaseDate,
          ),
        );
      }

      return candidates;
    } on _AlbumArtHttpException catch (error) {
      if (error.statusCode == 404) {
        return const [];
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final response = await _client
        .get(uri, headers: _jsonHeaders())
        .timeout(_requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _AlbumArtHttpException(
        statusCode: response.statusCode,
        message: 'HTTP ${response.statusCode}',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const AlbumArtImportException(
        'Artwork lookup returned invalid data.',
      );
    }

    return decoded;
  }

  Map<String, String> _jsonHeaders() {
    return const {
      'Accept': 'application/json',
      'User-Agent': 'FlickPlayer/0.12.0 (album-art-lookup)',
    };
  }

  Map<String, String> _downloadHeaders() {
    return const {'User-Agent': 'FlickPlayer/0.12.0 (album-art-lookup)'};
  }

  Future<AlbumGroup> _resolveAlbumGroup(Song song) async {
    final group = await _songRepository.getAlbumGroupForSong(song);
    if (group == null || group.songs.isEmpty) {
      throw const AlbumArtImportException(
        'Could not resolve the album for this song.',
      );
    }
    return group;
  }

  List<String> _albumFilePaths(AlbumGroup group) {
    final filePaths = group.songs
        .map((entry) => entry.filePath)
        .whereType<String>()
        .where((path) => path.isNotEmpty)
        .toSet()
        .toList();
    if (filePaths.isEmpty) {
      throw const AlbumArtImportException(
        'No library files were found for this album.',
      );
    }
    return filePaths;
  }

  Future<File> _writeCustomArtwork(String albumKey, Uint8List bytes) async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final artworkDirectory = Directory(
      '${documentsDirectory.path}${Platform.pathSeparator}$_customArtworkDirectoryName',
    );
    if (!await artworkDirectory.exists()) {
      await artworkDirectory.create(recursive: true);
    }

    final digest = md5.convert(utf8.encode(albumKey)).toString();
    final file = File(
      '${artworkDirectory.path}${Platform.pathSeparator}$digest.cover',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  List<AlbumArtCandidate> _dedupeCandidates(
    List<AlbumArtCandidate> candidates,
  ) {
    final deduped = <String, AlbumArtCandidate>{};
    for (final candidate in candidates) {
      deduped.putIfAbsent(candidate.imageUrl, () => candidate);
    }
    return deduped.values.take(12).toList(growable: false);
  }

  String _buildMusicBrainzQuery({
    required String titleField,
    required String album,
    required String artist,
  }) {
    final clauses = <String>['$titleField:"${_escapeQueryValue(album)}"'];
    if (artist.trim().isNotEmpty) {
      clauses.add('artist:"${_escapeQueryValue(artist)}"');
    }
    return clauses.join(' AND ');
  }

  String _escapeQueryValue(String value) {
    return value.replaceAll('"', ' ').trim();
  }

  String _artistCreditLabel(Object? artistCredit) {
    if (artistCredit is! List) {
      return '';
    }

    final parts = <String>[];
    for (final item in artistCredit) {
      if (item is! Map<String, dynamic>) {
        continue;
      }

      final name = (item['name'] as String?)?.trim();
      if (name != null && name.isNotEmpty) {
        parts.add(name);
      }

      final joinPhrase = item['joinphrase'] as String?;
      if (joinPhrase != null && joinPhrase.isNotEmpty) {
        parts.add(joinPhrase);
      }
    }

    return parts.join();
  }

  int _matchScore({
    required String title,
    required String artist,
    required String album,
    required String expectedArtist,
    String? primaryType,
  }) {
    final normalizedTitle = _normalize(title);
    final normalizedAlbum = _normalize(album);
    final normalizedArtist = _normalize(artist);
    final normalizedExpectedArtist = _normalize(expectedArtist);

    var score = 0;
    if (normalizedTitle == normalizedAlbum) {
      score += 120;
    } else if (normalizedTitle.contains(normalizedAlbum) ||
        normalizedAlbum.contains(normalizedTitle)) {
      score += 70;
    }

    if (normalizedExpectedArtist.isNotEmpty) {
      if (normalizedArtist == normalizedExpectedArtist) {
        score += 60;
      } else if (normalizedArtist.contains(normalizedExpectedArtist) ||
          normalizedExpectedArtist.contains(normalizedArtist)) {
        score += 30;
      }
    }

    if ((primaryType ?? '').toLowerCase() == 'album') {
      score += 10;
    }

    return score;
  }

  String _normalize(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  }

  String? _searchAlbumName(Song song) {
    final album = song.album?.trim();
    if (album == null || album.isEmpty) {
      return null;
    }
    return album;
  }

  String _searchArtistName(Song song) {
    final albumArtist = song.albumArtist?.trim();
    if (albumArtist != null && albumArtist.isNotEmpty) {
      return albumArtist;
    }
    return song.artist.trim();
  }

  bool _looksLikeImage(Uint8List bytes) {
    if (bytes.isEmpty) {
      return false;
    }

    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return true;
    }

    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return true;
    }

    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true;
    }

    if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      return true;
    }

    if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
      return true;
    }

    return false;
  }

  AlbumArtImportException _asImportException(Object error) {
    if (error is AlbumArtImportException) {
      return error;
    }
    if (error is _AlbumArtHttpException) {
      if (error.statusCode == 503) {
        return const AlbumArtImportException(
          'Artwork lookup is temporarily unavailable.',
        );
      }
      return AlbumArtImportException(
        'Artwork lookup failed (HTTP ${error.statusCode}).',
      );
    }
    return const AlbumArtImportException('Failed to search album art online.');
  }
}

class _MusicBrainzMatch {
  const _MusicBrainzMatch({
    required this.id,
    required this.entityType,
    required this.title,
    required this.artist,
    required this.releaseDate,
    required this.score,
  });

  final String id;
  final String entityType;
  final String title;
  final String artist;
  final String? releaseDate;
  final int score;
}

class _AlbumArtHttpException implements Exception {
  const _AlbumArtHttpException({
    required this.statusCode,
    required this.message,
  });

  final int statusCode;
  final String message;

  @override
  String toString() => message;
}
