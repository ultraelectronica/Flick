import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../data/database.dart';
import '../data/entities/song_entity.dart';
import '../data/repositories/song_repository.dart';
import '../data/repositories/folder_repository.dart';
import '../services/music_folder_service.dart';
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

  bool _isCancelled = false;

  LibraryScannerService({
    SongRepository? songRepository,
    FolderRepository? folderRepository,
    MusicFolderService? musicFolderService,
  }) : _songRepository = songRepository ?? SongRepository(),
       _folderRepository = folderRepository ?? FolderRepository(),
       _musicFolderService = musicFolderService ?? MusicFolderService();

  void cancelScan() {
    _isCancelled = true;
  }

  /// Scan a single folder using appropriate method for platform.
  Stream<ScanProgress> scanFolder(String folderUri, String displayName) async* {
    if (Platform.isAndroid) {
      yield* _scanFolderAndroid(folderUri, displayName);
    } else {
      yield* _scanFolderRust(folderUri, displayName);
    }
  }

  Stream<ScanProgress> _scanFolderAndroid(
    String folderUri,
    String displayName,
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
      fastScanFiles = await _musicFolderService.scanFolder(folderUri);
    } catch (e) {
      debugPrint("Error scanning Android folder: $e");
      return;
    }

    if (_isCancelled) return;

    // 2. Diff Logic
    final existingSongs = await _songRepository.getSongEntitiesByFolder(
      folderUri,
    );
    final existingMap = {for (var s in existingSongs) s.filePath: s};
    final fastScanMap = {for (var f in fastScanFiles) f.uri: f};

    // Calculate variations
    final scannedUris = fastScanMap.keys.toSet();

    // Deletions: in DB but not in scan
    final urisToDelete = existingMap.keys
        .where((uri) => !scannedUris.contains(uri))
        .toList();

    if (urisToDelete.isNotEmpty) {
      await _songRepository.deleteSongsByPath(urisToDelete);
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

        // Check for modification OR missing new metadata (Album Art / Bitrate)
        // This forces a rescan for files that haven't changed but need new fields.
        final missingMetadata =
            existing.albumArtPath == null && existing.bitrate == null;

        if (file.lastModified != existingTime || missingMetadata) {
          urisToProcess.add(file.uri);
        }
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

    const chunkSize = 50;
    for (var i = 0; i < urisToProcess.length; i += chunkSize) {
      if (_isCancelled) break;

      final end = (i + chunkSize < urisToProcess.length)
          ? i + chunkSize
          : urisToProcess.length;
      final chunkUris = urisToProcess.sublist(i, end);

      // Fetch Metadata for chunk
      List<AudioFileInfo> metadataList = [];
      try {
        metadataList = await _musicFolderService.fetchMetadata(chunkUris);
      } catch (e) {
        debugPrint("Error fetching metadata chunk: $e");
        continue;
      }

      for (var meta in metadataList) {
        if (meta.albumArtPath != null && meta.albumArtPath!.isNotEmpty) {
          debugPrint(
            "Successfully found album cover for ${meta.title}: ${meta.albumArtPath}",
          );
        }
      }

      final batch = <SongEntity>[];
      for (final meta in metadataList) {
        // Merge with basic info
        final basic = fastScanMap[meta.uri];
        if (basic == null) continue; // Should not happen

        final song = SongEntity()
          ..filePath = basic.uri
          ..title = meta.title ?? basic.name
          ..artist = meta.artist ?? 'Unknown Artist'
          ..album = meta.album ?? 'Unknown Album'
          ..durationMs = meta.duration ?? 0
          ..fileType = basic.extension.toUpperCase()
          ..dateAdded = existingMap[basic.uri]?.dateAdded ?? DateTime.now()
          ..lastModified = DateTime.fromMillisecondsSinceEpoch(
            basic.lastModified,
          )
          ..folderUri = folderUri
          ..fileSize = basic.size
          ..albumArtPath = meta.albumArtPath
          ..bitrate = meta.bitrate != null ? int.tryParse(meta.bitrate!) : null;

        // Restore ID if updating
        if (existingMap.containsKey(basic.uri)) {
          song.id = existingMap[basic.uri]!.id;
        }

        batch.add(song);
      }

      if (batch.isNotEmpty) {
        await _songRepository.upsertSongs(batch);
      }

      processed += chunkUris.length;

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
    String folderUri,
    String displayName,
  ) async* {
    _isCancelled = false;

    yield ScanProgress(
      songsFound: 0,
      totalFiles: 0,
      currentFolder: displayName,
      isComplete: false,
    );

    // 1. Fetch existing file state from DB
    final existingSongs = await _songRepository.getAllSongEntities();
    final knownFiles = <String, int>{};
    final existingMap = <String, SongEntity>{};

    for (var song in existingSongs) {
      existingMap[song.filePath] = song;
      // Only consider file "known" (up to date) if it has new metadata fields.
      // Otherwise, exclude it so Rust scanner treats it as new and extracts metadata.
      final hasMetadata = song.albumArtPath != null || song.bitrate != null;

      if (song.lastModified != null && hasMetadata) {
        // Rust expects seconds for comparison usually, or matches implementation
        // ScanResult sends back lastModified in seconds usually, let's check.
        // Rust side: `known_files.get(&path_str)` ... `modified > known_timestamp`
        // Dart side sends ms/1000.
        knownFiles[song.filePath] =
            song.lastModified!.millisecondsSinceEpoch ~/ 1000;
      }
    }

    // 2. Call Rust Scanner
    final result = await scanRootDir(
      rootPath: folderUri,
      knownFiles: knownFiles,
    );

    // 3. Process Deletions
    if (result.deletedPaths.isNotEmpty) {
      await _songRepository.deleteSongsByPath(result.deletedPaths);
    }

    // 4. Process New/Modified
    int processed = 0;
    int total = result.newOrModified.length;

    // Batch insert
    final batch = <SongEntity>[];
    const batchSize = 100;

    for (final metadata in result.newOrModified) {
      if (_isCancelled) break;

      final existing = existingMap[metadata.path];

      final song = SongEntity()
        ..filePath = metadata.path
        ..title =
            metadata.title ??
            _extractTitleFromFilename(metadata.path.split('/').last)
        ..artist = metadata.artist ?? 'Unknown Artist'
        ..album = metadata.album
        ..durationMs = metadata.durationSecs != null
            ? (metadata.durationSecs! * BigInt.from(1000)).toInt()
            : 0
        ..fileType = metadata.format.toUpperCase()
        ..dateAdded = existing?.dateAdded ?? DateTime.now()
        ..lastModified = DateTime.fromMillisecondsSinceEpoch(
          metadata.lastModified * 1000,
        )
        ..folderUri = folderUri;

      if (existing != null) {
        song.id = existing.id;
      }

      batch.add(song);
      processed++;

      if (batch.length >= batchSize) {
        await _songRepository.upsertSongs(batch);
        batch.clear();

        yield ScanProgress(
          songsFound: processed,
          totalFiles:
              total, // Approximate total since we only know new/modified count here + deletions
          currentFile: song.title,
          currentFolder: displayName,
          isComplete: false,
        );
      }
    }

    if (batch.isNotEmpty) {
      await _songRepository.upsertSongs(batch);
    }

    // Update folder stats
    final finalCount = await _songRepository.countSongsInFolder(folderUri);
    await _folderRepository.updateFolderScanInfo(folderUri, finalCount);

    yield ScanProgress(
      songsFound: processed,
      totalFiles: total,
      currentFolder: displayName,
      isComplete: true,
    );
  }

  Stream<ScanProgress> scanAllFolders() async* {
    _isCancelled = false;
    final folders = await _folderRepository
        .getAllFolders(); // Assuming repository has this

    for (final folder in folders) {
      if (_isCancelled) break;
      await for (final progress in scanFolder(folder.uri, folder.displayName)) {
        yield progress;
      }
    }
  }

  String _extractTitleFromFilename(String filename) {
    final dotIndex = filename.lastIndexOf('.');
    String name = dotIndex > 0 ? filename.substring(0, dotIndex) : filename;
    name = name.replaceFirst(RegExp(r'^\d{1,3}[\s._-]+'), '');
    name = name.replaceAll('_', ' ');
    return name.trim().replaceAll(RegExp(r'\s+'), ' ');
  }
}
