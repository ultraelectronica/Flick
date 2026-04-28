import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flick/services/android_audio_device_service.dart';
import '../core/utils/audio_metadata_utils.dart';
import '../data/database.dart';
import '../data/repositories/song_repository.dart';
import '../data/repositories/folder_repository.dart';
import '../services/music_folder_service.dart';
import '../services/library_scan_preferences_service.dart';
import '../services/playlist_service.dart';
import '../services/cue_file_service.dart';
import '../services/rip_log_service.dart';
import '../src/rust/api/scanner.dart'; // Rust bridge

/// Progress update during library scanning.
class ScanProgress {
  final int songsFound;
  final int totalFiles;
  final String? currentFile;
  final String? currentFolder;
  final bool isComplete;

  ScanProgress({
    required this.songsFound,
    required this.totalFiles,
    this.currentFile,
    this.currentFolder,
    this.isComplete = false,
  });
}

/// Service for scanning music folders and indexing songs in the database.
class LibraryScannerService {
  final SongRepository _songRepository;
  final FolderRepository _folderRepository;
  final MusicFolderService _musicFolderService;
  final LibraryScanPreferencesService _scanPreferencesService;
  final PlaylistService _playlistService;

  bool _isCancelled = false;
  final Set<String> _currentlyScanning = {};

  static const MethodChannel _storageChannel = MethodChannel(
    'com.ultraelectronica.flick/storage',
  );

  LibraryScannerService({
    SongRepository? songRepository,
    FolderRepository? folderRepository,
    MusicFolderService? musicFolderService,
    LibraryScanPreferencesService? scanPreferencesService,
    PlaylistService? playlistService,
  }) : _songRepository = songRepository ?? SongRepository(),
       _folderRepository = folderRepository ?? FolderRepository(),
       _musicFolderService = musicFolderService ?? MusicFolderService(),
       _scanPreferencesService =
           scanPreferencesService ?? LibraryScanPreferencesService(),
       _playlistService = playlistService ?? PlaylistService();

  void cancelScan() {
    _isCancelled = true;
  }

  /// Scan a single folder using appropriate method for platform.
  Stream<ScanProgress> scanFolder(String folderUri, String displayName) async* {
    final scanKey = normalizeFolderIdentifier(folderUri);
    final scanPreferences = await _scanPreferencesService.getPreferences();

    // Prevent concurrent scans of the same folder
    if (_currentlyScanning.contains(scanKey)) {
      debugPrint('Folder $displayName is already being scanned, skipping...');
      return;
    }

    _currentlyScanning.add(scanKey);
    try {
      if (Platform.isAndroid) {
        final deviceInfo = await AndroidAudioDeviceService.instance.refresh();
        final shouldPreferSafScan = deviceInfo.isXiaomiDevice;
        final resolvedScanRoot = await _musicFolderService
            .resolveFilesystemPath(folderUri);

        if (!shouldPreferSafScan &&
            resolvedScanRoot != null &&
            resolvedScanRoot.isNotEmpty) {
          try {
            yield* _scanFolderRust(
              resolvedScanRoot,
              folderUri,
              displayName,
              scanPreferences,
            );
            return;
          } catch (e) {
            debugPrint(
              'Rust Android scan fallback for $displayName failed at $resolvedScanRoot: $e',
            );
          }
        }

        if (shouldPreferSafScan) {
          debugPrint(
            'Using SAF scan path for $displayName on Xiaomi-family device',
          );
        }

        yield* _scanFolderAndroid(folderUri, displayName, scanPreferences);
      } else {
        yield* _scanFolderRust(
          folderUri,
          folderUri,
          displayName,
          scanPreferences,
        );
      }
    } finally {
      _currentlyScanning.remove(scanKey);
    }
  }

  Stream<ScanProgress> _scanFolderAndroid(
    String folderUri,
    String displayName,
    LibraryScanPreferences scanPreferences,
  ) async* {
    _isCancelled = false;
    yield ScanProgress(
      songsFound: 0,
      totalFiles: 0,
      currentFolder: displayName,
      isComplete: false,
    );

    // 1. Fast Scan: Get all files with basic info only
    List<AudioFileInfo> fastScanFiles = [];
    try {
      fastScanFiles = await _musicFolderService.scanFolder(
        folderUri,
        filterNonMusicFilesAndFolders:
            scanPreferences.filterNonMusicFilesAndFolders,
      );
    } catch (e) {
      debugPrint("Error scanning Android folder: $e");
      return;
    }

    if (_isCancelled) return;

    // 2. Diff Logic
    final existingSongs = await _songRepository.getSongEntitiesByFolder(
      folderUri,
    );
    final filteredExistingSongs = await _purgeExistingSongsFilteredByRules(
      existingSongs,
      scanPreferences,
    );
    final existingMap = {for (var s in existingSongs) s.filePath: s};
    for (final song in filteredExistingSongs) {
      existingMap.remove(song.filePath);
    }
    final fastScanMap = {for (var f in fastScanFiles) f.uri: f};

    // 2b. Parse CUE and log files
    final cueFiles = fastScanFiles.where((f) =>
        f.extension.toLowerCase() == 'cue').toList();
    final logFiles = fastScanFiles.where((f) {
      final ext = f.extension.toLowerCase();
      return ext == 'log' || ext == 'txt';
    }).toList();

    final cueMap = cueFiles.isNotEmpty
        ? await _parseCueFilesAndroid(cueFiles, fastScanMap)
        : <String, CueSheet>{};
    final logMap = logFiles.isNotEmpty
        ? await _parseLogFilesAndroid(logFiles, fastScanMap)
        : <String, RipLog>{};

    // Calculate variations
    final scannedUris = fastScanMap.keys.toSet();

    // Deletions: in DB but not in scan
    final urisToDelete = existingMap.keys
        .where((uri) => !scannedUris.contains(uri))
        .toList();

    if (urisToDelete.isNotEmpty) {
      final idsToDelete = urisToDelete
          .map((uri) => existingMap[uri]?.id)
          .whereType<int>()
          .toList();
      if (idsToDelete.isNotEmpty) {
        await _songRepository.deleteSongsByIds(idsToDelete);
      } else {
        await _songRepository.deleteSongsByPath(urisToDelete);
      }
    }

    // Delete orphaned CUE tracks (audio file in scan but no CUE file)
    final audioFilesWithCue = cueMap.keys.toSet();
    final existingCuePaths = existingSongs
        .where((s) => s.startOffsetMs != null)
        .map((s) => s.filePath)
        .toSet();
    final orphanedCuePaths = existingCuePaths
        .where((p) => scannedUris.contains(p) && !audioFilesWithCue.contains(p))
        .toList();
    if (orphanedCuePaths.isNotEmpty) {
      await _songRepository.deleteCueTracksByPath(orphanedCuePaths);
    }

    // Updates: New files or Modified files
    final urisToProcess = <String>[];
    for (final file in fastScanFiles) {
      final existing = existingMap[file.uri];
      if (existing == null) {
        // New file
        urisToProcess.add(file.uri);
      } else {
        // Check modification time (DB stores DateTime, File has int timestamp)
        // DateTime.millisecondsSinceEpoch == file.lastModified (if file.lastModified is ms)
        // Wait, MusicFolderService parses lastModified as int.
        // Android DocumentFile.lastModified() returns MS.
        // SongEntity.lastModified is DateTime.

        final existingTime = existing.lastModified?.millisecondsSinceEpoch ?? 0;

        // Check for modification OR missing text/audio properties.
        final currentFileType = file.extension.trim().toUpperCase();
        final storedFileType = existing.fileType?.trim().toUpperCase();
        final fileTypeMismatch =
            currentFileType.isNotEmpty &&
            (storedFileType == null || storedFileType != currentFileType);
        final missingMetadata =
            existing.bitrate == null ||
            existing.sampleRate == null ||
            existing.bitDepth == null ||
            existing.trackNumber == null ||
            existing.discNumber == null ||
            existing.albumArtist == null ||
            fileTypeMismatch;

        if (file.lastModified != existingTime || missingMetadata) {
          urisToProcess.add(file.uri);
        }
      }
    }

    // Ensure audio files referenced by CUE sheets are processed
    for (final audioUri in cueMap.keys) {
      if (!urisToProcess.contains(audioUri)) {
        urisToProcess.add(audioUri);
      }
    }

    // 3. Process Metadata in Chunks
    int processed = 0;

    // UX Metric: Total files found in filesystem
    int totalFiles = fastScanFiles.length;

    // UX Metric: Initial "Songs Found" = Existing - Deleted
    int initialSongCount = existingMap.length - urisToDelete.length;

    // Report initial state after diff
    yield ScanProgress(
      songsFound: initialSongCount,
      totalFiles: totalFiles,
      currentFolder: displayName,
      isComplete: false,
    );

    final metadataBatchSize = _recommendedMetadataBatchSize(
      urisToProcess.length,
    );
    final metadataChunks = _chunkList(urisToProcess, metadataBatchSize);

    for (final chunkUris in metadataChunks) {
      if (_isCancelled) break;

      final metadataList = await _fetchMetadataChunk(chunkUris);
      if (metadataList == null) {
        continue;
      }

      final batch = <SongEntity>[];
      final idsToDelete = <int>[];
      final metadataByUri = <String, AudioFileInfo>{
        for (final meta in metadataList) meta.uri: meta,
      };

      for (final uri in chunkUris) {
        final basic = fastScanMap[uri];
        if (basic == null) continue;

        final meta = metadataByUri[uri];
        final existing = existingMap[basic.uri];
        final looksLikeAudio =
            _looksLikeSupportedAudioExtension(basic.extension) ||
            (meta?.mimeType?.toLowerCase().startsWith('audio/') ?? false) ||
            ((meta?.duration ?? 0) > 0);
        if (!looksLikeAudio) {
          continue;
        }

        final cueSheet = cueMap[basic.uri];
        final ripLog = logMap[basic.uri];

        if (cueSheet != null) {
          // Delete raw entity for this audio file if present
          if (existing != null && existing.startOffsetMs == null) {
            idsToDelete.add(existing.id);
          }

          final cueEntities = _buildCueTrackEntities(
            audioUri: basic.uri,
            cueSheet: cueSheet,
            meta: meta ?? basic,
            folderUri: folderUri,
            existingMap: existingMap,
            ripLog: ripLog,
            lastModified: DateTime.fromMillisecondsSinceEpoch(
              basic.lastModified,
            ),
          );

          for (final entity in cueEntities) {
            if (_shouldIgnoreDiscoveredTrack(
              fileSizeBytes: entity.fileSize,
              durationMs: entity.durationMs,
              scanPreferences: scanPreferences,
            )) {
              continue;
            }
            batch.add(entity);
          }
          continue;
        }

        final artist = (meta?.artist?.trim().isNotEmpty ?? false)
            ? meta!.artist!.trim()
            : 'Unknown Artist';
        final song = SongEntity()
          ..filePath = basic.uri
          ..title = (meta?.title?.trim().isNotEmpty ?? false)
              ? meta!.title!.trim()
              : _extractTitleFromFilename(basic.name)
          ..artist = artist
          ..album = (meta?.album?.trim().isNotEmpty ?? false)
              ? meta!.album!.trim()
              : 'Unknown Album'
          ..albumArtist = (meta?.albumArtist?.trim().isNotEmpty ?? false)
              ? meta!.albumArtist!.trim()
              : artist
          // 0 is used as a persisted sentinel for "unknown track" so we can
          // migrate old rows once without forcing rescans forever.
          ..trackNumber = meta?.trackNumber ?? 0
          ..discNumber = meta?.discNumber ?? 1
          ..durationMs = meta?.duration ?? 0
          ..fileType = basic.extension.toUpperCase()
          ..dateAdded = existingMap[basic.uri]?.dateAdded ?? DateTime.now()
          ..lastModified = DateTime.fromMillisecondsSinceEpoch(
            basic.lastModified,
          )
          ..folderUri = folderUri
          ..fileSize = basic.size
          ..albumArtPath = existingMap[basic.uri]?.albumArtPath
          ..bitrate = meta?.bitrate != null
              ? AudioMetadataUtils.bitrateFromBitsPerSecond(
                  int.tryParse(meta!.bitrate!),
                )
              : null
          ..bitDepth = meta?.bitDepth
          ..sampleRate = meta?.sampleRate
          ..ripper = ripLog?.ripper
          ..readMode = ripLog?.readMode
          ..accurateRip = ripLog?.accurateRipEnabled;

        if (existing != null) {
          song.id = existing.id;
        }

        if (_shouldIgnoreDiscoveredTrack(
          fileSizeBytes: basic.size,
          durationMs: song.durationMs,
          scanPreferences: scanPreferences,
        )) {
          if (existing != null) {
            idsToDelete.add(existing.id);
          }
          continue;
        }

        batch.add(song);
      }

      if (idsToDelete.isNotEmpty) {
        await _songRepository.deleteSongsByIds(idsToDelete);
      }

      if (batch.isNotEmpty) {
        await _songRepository.upsertSongs(batch);
      }

      processed += batch.length;

      yield ScanProgress(
        songsFound: initialSongCount + processed,
        totalFiles: totalFiles,
        currentFile: batch.isNotEmpty ? batch.last.title : null,
        currentFolder: displayName,
        isComplete: false,
      );
    }

    // Update folder stats
    final finalCount = await _songRepository.countSongsInFolder(folderUri);
    await _folderRepository.updateFolderScanInfo(folderUri, finalCount);
    await _syncPlaylistSourcesForFolder(folderUri, scanPreferences);

    yield ScanProgress(
      // This is "processed changes".
      // Maybe UI expects "Total Songs"?
      // ScanProgress definition: songsFound, totalFiles.
      // Usually 'songsFound' implies total songs in library.
      // Let's return finalCount.
      songsFound: finalCount,
      totalFiles: totalFiles,
      currentFolder: displayName,
      isComplete: true,
    );
  }

  Stream<ScanProgress> _scanFolderRust(
    String scanRootPath,
    String folderUri,
    String displayName,
    LibraryScanPreferences scanPreferences,
  ) async* {
    _isCancelled = false;

    yield ScanProgress(
      songsFound: 0,
      totalFiles: 0,
      currentFolder: displayName,
      isComplete: false,
    );

    // 1. Fetch existing file state from DB
    final existingSongs = await _songRepository.getSongEntitiesByFolder(
      folderUri,
    );
    final filteredExistingSongs = await _purgeExistingSongsFilteredByRules(
      existingSongs,
      scanPreferences,
    );
    final knownFiles = <String, int>{};
    final existingMap = <String, SongEntity>{};

    for (var song in existingSongs) {
      if (filteredExistingSongs.contains(song)) {
        continue;
      }
      existingMap[song.filePath] = song;
      if (song.lastModified != null) {
        knownFiles[song.filePath] = song.lastModified!.millisecondsSinceEpoch;
      }
    }

    // 2. Stream scan batches from Rust
    int processed = 0;
    int totalFiles = 0;
    int initialSongCount = existingMap.length;
    bool initialProgressSent = false;

    await for (final chunk in scanMusicLibrary(
      rootPath: scanRootPath,
      knownFiles: knownFiles,
      scanOptions: ScanOptions(
        filterNonMusicFilesAndFolders:
            scanPreferences.filterNonMusicFilesAndFolders,
      ),
    )) {
      if (_isCancelled) {
        break;
      }

      totalFiles = chunk.totalFiles;

      if (!initialProgressSent) {
        if (chunk.deletedPaths.isNotEmpty) {
          final idsToDelete = chunk.deletedPaths
              .map((path) => existingMap[path]?.id)
              .whereType<int>()
              .toList();
          if (idsToDelete.isNotEmpty) {
            await _songRepository.deleteSongsByIds(idsToDelete);
          } else {
            await _songRepository.deleteSongsByPath(chunk.deletedPaths);
          }
        }

        initialSongCount = existingMap.length - chunk.deletedPaths.length;
        initialProgressSent = true;

        yield ScanProgress(
          songsFound: initialSongCount,
          totalFiles: totalFiles,
          currentFolder: displayName,
          isComplete: false,
        );
      }

      if (chunk.newOrModified.isNotEmpty) {
        final batch = <SongEntity>[];
        final idsToDelete = <int>[];

        for (final metadata in chunk.newOrModified) {
          final existing = existingMap[metadata.path];
          final artist = (metadata.artist?.trim().isNotEmpty ?? false)
              ? metadata.artist!.trim()
              : 'Unknown Artist';
          final song = SongEntity()
            ..filePath = metadata.path
            ..title = (metadata.title?.trim().isNotEmpty ?? false)
                ? metadata.title!.trim()
                : _extractTitleFromFilename(metadata.path.split('/').last)
            ..artist = artist
            ..album = (metadata.album?.trim().isNotEmpty ?? false)
                ? metadata.album!.trim()
                : 'Unknown Album'
            ..albumArtist = existing?.albumArtist ?? artist
            ..trackNumber = metadata.trackNumber ?? existing?.trackNumber ?? 0
            ..discNumber = metadata.discNumber ?? existing?.discNumber ?? 1
            ..durationMs = metadata.durationMs?.toInt() ?? 0
            ..fileType = metadata.format.toUpperCase()
            ..dateAdded = existing?.dateAdded ?? DateTime.now()
            ..lastModified = DateTime.fromMillisecondsSinceEpoch(
              metadata.lastModified,
            )
            ..folderUri = folderUri
            ..fileSize = metadata.fileSize.toInt()
            ..albumArtPath = existing?.albumArtPath
            ..bitrate = AudioMetadataUtils.normalizeStoredBitrateKbps(
              metadata.bitrate,
              sampleRate: metadata.sampleRate,
              bitDepth: metadata.bitDepth,
            )
            ..bitDepth = metadata.bitDepth
            ..sampleRate = metadata.sampleRate;

          if (existing != null) {
            song.id = existing.id;
          }

          if (_shouldIgnoreDiscoveredTrack(
            fileSizeBytes: metadata.fileSize.toInt(),
            durationMs: song.durationMs,
            scanPreferences: scanPreferences,
          )) {
            if (existing != null) {
              idsToDelete.add(existing.id);
            }
            continue;
          }

          batch.add(song);
        }

        if (idsToDelete.isNotEmpty) {
          await _songRepository.deleteSongsByIds(idsToDelete);
        }

        if (batch.isNotEmpty) {
          await _songRepository.upsertSongs(batch);
        }
        processed += batch.length;

        yield ScanProgress(
          songsFound: initialSongCount + processed,
          totalFiles: totalFiles,
          currentFile: batch.isNotEmpty ? batch.last.title : null,
          currentFolder: displayName,
          isComplete: false,
        );
      }
    }

    // Post-process CUE and log files
    if (!_isCancelled) {
      final cueMap = await _parseCueFilesRust(scanRootPath);
      final logMap = await _parseLogFilesRust(scanRootPath);

      if (cueMap.isNotEmpty || logMap.isNotEmpty) {
        final existingSongsAfterScan =
            await _songRepository.getSongEntitiesByFolder(folderUri);
        final existingMapAfterScan = <String, SongEntity>{
          for (var s in existingSongsAfterScan) s.filePath: s,
        };

        // Delete orphaned CUE tracks
        final existingCuePaths = existingSongsAfterScan
            .where((s) => s.startOffsetMs != null)
            .map((s) => s.filePath)
            .toSet();
        final orphanedCuePaths = existingCuePaths
            .where((p) => !cueMap.containsKey(p))
            .toList();
        if (orphanedCuePaths.isNotEmpty) {
          await _songRepository.deleteCueTracksByPath(orphanedCuePaths);
        }

        // Process CUE files
        for (final entry in cueMap.entries) {
          final audioPath = entry.key;
          final cueSheet = entry.value;
          final existing = existingMapAfterScan[audioPath];

          // Delete raw entity if present
          if (existing != null && existing.startOffsetMs == null) {
            await _songRepository.deleteSongsByIds([existing.id]);
          }

          // Re-fetch existing CUE tracks for this path to preserve IDs
          final cueExistingMap = <String, SongEntity>{};
          final cueTracksInDb = existingSongsAfterScan
              .where((s) => s.filePath == audioPath && s.startOffsetMs != null);
          for (final s in cueTracksInDb) {
            cueExistingMap['${s.filePath}#${s.startOffsetMs}'] = s;
          }

          final ripLog = logMap[audioPath];
          final lastModified = existing?.lastModified ??
              DateTime.fromMillisecondsSinceEpoch(
                DateTime.now().millisecondsSinceEpoch,
              );

          final entities = _buildCueTrackEntities(
            audioUri: audioPath,
            cueSheet: cueSheet,
            meta: null,
            folderUri: folderUri,
            existingMap: cueExistingMap,
            ripLog: ripLog,
            lastModified: lastModified,
          );

          if (entities.isNotEmpty) {
            await _songRepository.upsertSongs(entities);
          }
        }

        // Apply log metadata to raw audio files without CUE
        for (final entry in logMap.entries) {
          final audioPath = entry.key;
          if (cueMap.containsKey(audioPath)) continue;
          final existing = existingMapAfterScan[audioPath];
          if (existing == null) continue;
          existing.ripper = entry.value.ripper;
          existing.readMode = entry.value.readMode;
          existing.accurateRip = entry.value.accurateRipEnabled;
          await _songRepository.upsertSong(existing);
        }
      }
    }

    // Update folder stats
    final finalCount = await _songRepository.countSongsInFolder(folderUri);
    await _folderRepository.updateFolderScanInfo(folderUri, finalCount);
    await _syncPlaylistSourcesForFolder(
      folderUri,
      scanPreferences,
      scanRootPath: scanRootPath,
    );

    yield ScanProgress(
      songsFound: finalCount,
      totalFiles: totalFiles,
      currentFolder: displayName,
      isComplete: true,
    );
  }

  Stream<ScanProgress> scanAllFolders() async* {
    _isCancelled = false;
    final folders = await _folderRepository.getAllFolders();
    final scanPlan = _deduplicateFoldersForScan(folders);
    var runningLibrarySongCount = await _songRepository.getSongCount();

    for (final folder in scanPlan) {
      if (_isCancelled) break;
      final existingFolderSongCount = await _songRepository.countSongsInFolder(
        folder.uri,
      );

      await for (final progress in scanFolder(folder.uri, folder.displayName)) {
        final adjustedSongsFound =
            (runningLibrarySongCount - existingFolderSongCount) +
            progress.songsFound;
        final aggregatedProgress = ScanProgress(
          songsFound: adjustedSongsFound < 0 ? 0 : adjustedSongsFound,
          totalFiles: progress.totalFiles,
          currentFile: progress.currentFile,
          currentFolder: progress.currentFolder,
          isComplete: progress.isComplete,
        );

        if (progress.isComplete) {
          runningLibrarySongCount = aggregatedProgress.songsFound;
        }

        yield aggregatedProgress;
      }
    }
  }

  List<FolderEntity> _deduplicateFoldersForScan(List<FolderEntity> folders) {
    final sortedFolders = List<FolderEntity>.from(folders)
      ..sort((a, b) {
        final normalizedA = normalizeFolderIdentifier(a.uri);
        final normalizedB = normalizeFolderIdentifier(b.uri);
        final lengthCompare = normalizedA.length.compareTo(normalizedB.length);
        if (lengthCompare != 0) {
          return lengthCompare;
        }
        return normalizedA.compareTo(normalizedB);
      });

    final scheduledRoots = <String>{};
    final scanPlan = <FolderEntity>[];

    for (final folder in sortedFolders) {
      final normalized = normalizeFolderIdentifier(folder.uri);
      final overlapsExisting = scheduledRoots.any(
        (root) =>
            isSameOrDescendantFolder(normalized, root) ||
            isSameOrDescendantFolder(root, normalized),
      );
      if (overlapsExisting) {
        debugPrint(
          'Skipping overlapping scan root ${folder.displayName} (${folder.uri})',
        );
        continue;
      }
      scheduledRoots.add(normalized);
      scanPlan.add(folder);
    }

    return scanPlan;
  }

  String _extractTitleFromFilename(String filename) {
    final dotIndex = filename.lastIndexOf('.');
    String name = dotIndex > 0 ? filename.substring(0, dotIndex) : filename;
    name = name.replaceFirst(RegExp(r'^\d{1,3}[\s._-]+'), '');
    name = name.replaceAll('_', ' ');
    return name.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  Future<List<AudioFileInfo>?> _fetchMetadataChunk(
    List<String> chunkUris,
  ) async {
    try {
      return await _musicFolderService.fetchMetadata(chunkUris);
    } catch (e) {
      debugPrint(
        'Error fetching metadata chunk (${chunkUris.length} files): $e',
      );
      return null;
    }
  }

  int _recommendedMetadataBatchSize(int pendingFiles) {
    return pendingFiles <= 0 ? 100 : 500;
  }

  List<List<T>> _chunkList<T>(List<T> items, int chunkSize) {
    final chunks = <List<T>>[];
    for (var i = 0; i < items.length; i += chunkSize) {
      final end = (i + chunkSize < items.length) ? i + chunkSize : items.length;
      chunks.add(items.sublist(i, end));
    }
    return chunks;
  }

  Future<List<SongEntity>> _purgeExistingSongsFilteredByRules(
    List<SongEntity> existingSongs,
    LibraryScanPreferences scanPreferences,
  ) async {
    final filtered = existingSongs
        .where((song) => _shouldIgnoreStoredSong(song, scanPreferences))
        .toList();

    final ids = filtered.map((song) => song.id).toList();
    if (ids.isNotEmpty) {
      await _songRepository.deleteSongsByIds(ids);
    }

    return filtered;
  }

  bool _shouldIgnoreStoredSong(
    SongEntity song,
    LibraryScanPreferences scanPreferences,
  ) {
    return _shouldIgnoreDiscoveredTrack(
      fileSizeBytes: song.fileSize,
      durationMs: song.durationMs,
      scanPreferences: scanPreferences,
    );
  }

  bool _shouldIgnoreDiscoveredTrack({
    required int? fileSizeBytes,
    required int? durationMs,
    required LibraryScanPreferences scanPreferences,
  }) {
    if (scanPreferences.ignoreTracksSmallerThan500Kb &&
        fileSizeBytes != null &&
        fileSizeBytes > 0 &&
        fileSizeBytes < kIgnoredTrackMinSizeBytes) {
      return true;
    }

    if (scanPreferences.ignoreTracksShorterThan60Seconds &&
        durationMs != null &&
        durationMs > 0 &&
        durationMs < kIgnoredTrackMinDurationMs) {
      return true;
    }

    return false;
  }

  bool _looksLikeSupportedAudioExtension(String extension) {
    const supportedExtensions = {
      'mp3',
      'flac',
      'ogg',
      'oga',
      'ogx',
      'opus',
      'm4a',
      'wav',
      'aif',
      'aiff',
      'alac',
      'aac',
      'wma',
    };

    return supportedExtensions.contains(extension.trim().toLowerCase());
  }

  Future<void> _syncPlaylistSourcesForFolder(
    String folderUri,
    LibraryScanPreferences scanPreferences, {
    String? scanRootPath,
  }) async {
    if (_isCancelled || !scanPreferences.createPlaylistsFromM3uFiles) {
      return;
    }

    try {
      final sources = scanRootPath != null && scanRootPath.isNotEmpty
          ? await _discoverRustPlaylistSources(
              scanRootPath,
              folderUri,
              scanPreferences,
            )
          : Platform.isAndroid
          ? await _discoverAndroidPlaylistSources(folderUri, scanPreferences)
          : await _discoverRustPlaylistSources(
              folderUri,
              folderUri,
              scanPreferences,
            );
      if (sources.isEmpty) {
        return;
      }

      await _playlistService.syncPlaylistsFromSources(sources);
    } catch (e) {
      debugPrint('Failed to sync playlists from $folderUri: $e');
    }
  }

  Future<List<PlaylistSourceFile>> _discoverAndroidPlaylistSources(
    String folderUri,
    LibraryScanPreferences scanPreferences,
  ) async {
    final files = await _musicFolderService.scanPlaylistFiles(
      folderUri,
      filterNonMusicFilesAndFolders:
          scanPreferences.filterNonMusicFilesAndFolders,
    );

    return files
        .map(
          (file) =>
              PlaylistSourceFile(sourcePath: file.uri, displayName: file.name),
        )
        .toList();
  }

  Future<List<PlaylistSourceFile>> _discoverRustPlaylistSources(
    String scanRootPath,
    String folderUri,
    LibraryScanPreferences scanPreferences,
  ) async {
    final files = await discoverPlaylistFiles(
      rootPath: scanRootPath,
      scanOptions: ScanOptions(
        filterNonMusicFilesAndFolders:
            scanPreferences.filterNonMusicFilesAndFolders,
      ),
    );

    return files.map((path) => PlaylistSourceFile(sourcePath: path)).toList();
  }

  // ── CUE / Log helpers ──────────────────────────────────────────────

  Future<String?> _readTextFile(String uri) async {
    try {
      return await _storageChannel.invokeMethod<String>(
        'readTextDocument',
        {'uri': uri},
      );
    } catch (e) {
      debugPrint('[LibraryScanner] Failed to read text file $uri: $e');
      return null;
    }
  }

  String? _resolveAudioUriFromCue(
    String cueUri,
    String audioFileName,
    Map<String, AudioFileInfo> fastScanMap,
  ) {
    final target = audioFileName.toLowerCase();
    for (final entry in fastScanMap.values) {
      if (entry.name.toLowerCase() == target) {
        return entry.uri;
      }
    }
    return null;
  }

  Future<Map<String, CueSheet>> _parseCueFilesAndroid(
    List<AudioFileInfo> cueFiles,
    Map<String, AudioFileInfo> fastScanMap,
  ) async {
    final cueService = CueFileService();
    final result = <String, CueSheet>{};
    for (final cue in cueFiles) {
      final content = await _readTextFile(cue.uri);
      if (content == null || content.isEmpty) continue;
      final sheet = cueService.parseCueSheet(content, cueFilePath: cue.uri);
      if (sheet == null) continue;
      final audioUri = _resolveAudioUriFromCue(
        cue.uri,
        sheet.audioFile,
        fastScanMap,
      );
      if (audioUri != null) {
        result[audioUri] = sheet;
      }
    }
    return result;
  }

  Future<Map<String, RipLog>> _parseLogFilesAndroid(
    List<AudioFileInfo> logFiles,
    Map<String, AudioFileInfo> fastScanMap,
  ) async {
    final logService = RipLogService();
    final result = <String, RipLog>{};
    for (final log in logFiles) {
      final content = await _readTextFile(log.uri);
      if (content == null || content.isEmpty) continue;
      final ripLog = logService.parseLog(content);
      if (ripLog == null) continue;
      final logStem = _fileStem(log.name).toLowerCase();
      for (final entry in fastScanMap.values) {
        if (_looksLikeSupportedAudioExtension(entry.extension)) {
          final audioStem = _fileStem(entry.name).toLowerCase();
          if (audioStem == logStem) {
            result[entry.uri] = ripLog;
            break;
          }
        }
      }
    }
    return result;
  }

  Future<Map<String, CueSheet>> _parseCueFilesRust(
    String scanRootPath,
  ) async {
    final cueService = CueFileService();
    final result = <String, CueSheet>{};
    try {
      final dir = Directory(scanRootPath);
      if (!dir.existsSync()) return result;
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (_isCancelled) break;
        if (entity is! File) continue;
        final path = entity.path;
        if (!path.toLowerCase().endsWith('.cue')) continue;
        final content = await entity.readAsString().catchError((_) => '');
        if (content.isEmpty) continue;
        final sheet = cueService.parseCueSheet(content, cueFilePath: path);
        if (sheet == null) continue;
        final audioPath = cueService.resolveAudioFilePath(path, sheet.audioFile);
        result[audioPath] = sheet;
      }
    } catch (e) {
      debugPrint('[LibraryScanner] Error scanning for CUE files: $e');
    }
    return result;
  }

  Future<Map<String, RipLog>> _parseLogFilesRust(
    String scanRootPath,
  ) async {
    final logService = RipLogService();
    final result = <String, RipLog>{};
    try {
      final dir = Directory(scanRootPath);
      if (!dir.existsSync()) return result;
      final audioPaths = <String, String>{};
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File &&
            _looksLikeSupportedAudioExtension(
              entity.path.split('.').last.toLowerCase(),
            )) {
          final name = entity.path.split('/').last;
          final stem = _fileStem(name).toLowerCase();
          audioPaths[stem] = entity.path;
        }
      }
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (_isCancelled) break;
        if (entity is! File) continue;
        final path = entity.path;
        final ext = path.split('.').last.toLowerCase();
        if (ext != 'log' && ext != 'txt') continue;
        final content = await entity.readAsString().catchError((_) => '');
        if (content.isEmpty) continue;
        final ripLog = logService.parseLog(content);
        if (ripLog == null) continue;
        final name = path.split('/').last;
        final stem = _fileStem(name).toLowerCase();
        final audioPath = audioPaths[stem];
        if (audioPath != null) {
          result[audioPath] = ripLog;
        }
      }
    } catch (e) {
      debugPrint('[LibraryScanner] Error scanning for log files: $e');
    }
    return result;
  }

  String _fileStem(String fileName) {
    final lastDot = fileName.lastIndexOf('.');
    if (lastDot <= 0) return fileName;
    return fileName.substring(0, lastDot);
  }

  List<SongEntity> _buildCueTrackEntities({
    required String audioUri,
    required CueSheet cueSheet,
    required AudioFileInfo? meta,
    required String folderUri,
    required Map<String, SongEntity> existingMap,
    required RipLog? ripLog,
    required DateTime lastModified,
  }) {
    final entities = <SongEntity>[];
    for (final track in cueSheet.tracks) {
      final artist = track.performer.trim().isNotEmpty
          ? track.performer.trim()
          : (cueSheet.performer?.trim().isNotEmpty ?? false)
              ? cueSheet.performer!.trim()
              : (meta?.artist?.trim().isNotEmpty ?? false)
                  ? meta!.artist!.trim()
                  : 'Unknown Artist';
      final existing = existingMap['$audioUri#${track.startOffsetMs}'];
      final trackLog = ripLog?.tracks.firstWhere(
        (t) => t.trackNumber == track.trackNumber,
        orElse: () => const RipLogTrack(trackNumber: -1),
      );
      final entity = SongEntity()
        ..filePath = audioUri
        ..startOffsetMs = track.startOffsetMs
        ..endOffsetMs = track.endOffsetMs
        ..title = track.title.trim().isNotEmpty
            ? track.title.trim()
            : _extractTitleFromFilename(meta?.name ?? 'Track ${track.trackNumber}')
        ..artist = artist
        ..album = cueSheet.title?.trim().isNotEmpty ?? false
            ? cueSheet.title!.trim()
            : (meta?.album?.trim().isNotEmpty ?? false)
                ? meta!.album!.trim()
                : 'Unknown Album'
        ..albumArtist = cueSheet.performer?.trim().isNotEmpty ?? false
            ? cueSheet.performer!.trim()
            : artist
        ..trackNumber = track.trackNumber
        ..discNumber = meta?.discNumber ?? 1
        ..durationMs = track.endOffsetMs != null
            ? track.endOffsetMs! - track.startOffsetMs
            : (meta?.duration ?? 0)
        ..fileType = meta?.extension.toUpperCase() ?? 'UNKNOWN'
        ..dateAdded = existing?.dateAdded ?? DateTime.now()
        ..lastModified = lastModified
        ..folderUri = folderUri
        ..fileSize = meta?.size ?? 0
        ..albumArtPath = existing?.albumArtPath ?? meta?.albumArtPath
        ..bitrate = meta?.bitrate != null
            ? AudioMetadataUtils.bitrateFromBitsPerSecond(
                int.tryParse(meta!.bitrate!),
              )
            : null
        ..bitDepth = meta?.bitDepth
        ..sampleRate = meta?.sampleRate
        ..genre = cueSheet.genre
        ..year = int.tryParse(cueSheet.date ?? '')
        ..ripper = ripLog?.ripper
        ..readMode = ripLog?.readMode
        ..accurateRip = trackLog?.trackNumber == track.trackNumber
            ? trackLog?.accurate
            : null
        ..testCrc = trackLog?.trackNumber == track.trackNumber
            ? trackLog?.testCrc
            : null
        ..copyCrc = trackLog?.trackNumber == track.trackNumber
            ? trackLog?.copyCrc
            : null;

      if (existing != null) {
        entity.id = existing.id;
      }
      entities.add(entity);
    }
    return entities;
  }
}
