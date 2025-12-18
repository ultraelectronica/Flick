import 'dart:async';

import '../data/database.dart';
import '../data/entities/song_entity.dart';
import '../data/repositories/song_repository.dart';
import '../data/repositories/folder_repository.dart';
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

  bool _isCancelled = false;

  LibraryScannerService({
    SongRepository? songRepository,
    FolderRepository? folderRepository,
  }) : _songRepository = songRepository ?? SongRepository(),
       _folderRepository = folderRepository ?? FolderRepository();

  void cancelScan() {
    _isCancelled = true;
  }

  /// Scan a single folder using Rust scanner.
  Stream<ScanProgress> scanFolder(String folderUri, String displayName) async* {
    _isCancelled = false;

    yield ScanProgress(
      songsFound: 0,
      totalFiles: 0,
      currentFolder: displayName,
      isComplete: false,
    );

    // 1. Fetch existing file state from DB for this folder (or all folders if easier,
    // but per-folder is safer if URIs are reliable).
    // For now, let's fetch ALL songs to build the known map to avoid duplicates across moved files.
    // Optimization: In a real incremental scan of just one folder, we might only want that folder's files,
    // but to detect moves/duplicates, global knowledge is better.
    // Let's implement global fetch for now as it's safer against duplicates.
    final existingSongs = await _songRepository.getAllSongEntities();
    final knownFiles = <String, int>{};
    for (var song in existingSongs) {
      if (song.lastModified != null) {
        knownFiles[song.filePath] =
            song.lastModified!.millisecondsSinceEpoch ~/ 1000;
      }
    }

    // 2. Call Rust Scanner
    final result = scanRootDir(rootPath: folderUri, knownFiles: knownFiles);

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
        ..dateAdded = DateTime.now()
        ..lastModified = DateTime.fromMillisecondsSinceEpoch(
          metadata.lastModified * 1000,
        )
        ..folderUri = folderUri;

      batch.add(song);
      processed++;

      if (batch.length >= batchSize) {
        await _songRepository.upsertSongs(batch);
        batch.clear();

        yield ScanProgress(
          songsFound: processed,
          totalFiles: total,
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
