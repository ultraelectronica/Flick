import 'dart:async';

import '../data/database.dart';
import '../data/repositories/song_repository.dart';
import '../data/repositories/folder_repository.dart';
import 'music_folder_service.dart';

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
  final MusicFolderService _folderService;
  final SongRepository _songRepository;
  final FolderRepository _folderRepository;

  bool _isCancelled = false;

  LibraryScannerService({
    MusicFolderService? folderService,
    SongRepository? songRepository,
    FolderRepository? folderRepository,
  }) : _folderService = folderService ?? MusicFolderService(),
       _songRepository = songRepository ?? SongRepository(),
       _folderRepository = folderRepository ?? FolderRepository();

  /// Cancel the current scan.
  void cancelScan() {
    _isCancelled = true;
  }

  /// Scan a single folder and add songs to the database.
  /// Returns a stream of progress updates.
  Stream<ScanProgress> scanFolder(String folderUri, String displayName) async* {
    _isCancelled = false;
    int songsFound = 0;
    int totalFiles = 0;

    yield ScanProgress(
      songsFound: 0,
      totalFiles: 0,
      currentFolder: displayName,
      isComplete: false,
    );

    // Get audio files from folder
    final audioFiles = await _folderService.scanFolder(folderUri);
    totalFiles = audioFiles.length;

    yield ScanProgress(
      songsFound: 0,
      totalFiles: totalFiles,
      currentFolder: displayName,
      isComplete: false,
    );

    // Process files in batches
    final batch = <SongEntity>[];
    const batchSize = 50;

    for (final file in audioFiles) {
      if (_isCancelled) break;

      // Create song entity with basic info
      // Metadata extraction will be done via Rust in a future phase
      final entity = _createSongEntity(file, folderUri);
      batch.add(entity);
      songsFound++;

      // Batch insert
      if (batch.length >= batchSize) {
        await _songRepository.upsertSongs(batch);
        batch.clear();
      }

      yield ScanProgress(
        songsFound: songsFound,
        totalFiles: totalFiles,
        currentFile: file.name,
        currentFolder: displayName,
        isComplete: false,
      );
    }

    // Insert remaining songs
    if (batch.isNotEmpty) {
      await _songRepository.upsertSongs(batch);
    }

    // Update folder scan info
    await _folderRepository.updateFolderScanInfo(folderUri, songsFound);

    yield ScanProgress(
      songsFound: songsFound,
      totalFiles: totalFiles,
      currentFolder: displayName,
      isComplete: true,
    );
  }

  /// Scan all saved folders and update the library.
  Stream<ScanProgress> scanAllFolders() async* {
    _isCancelled = false;
    final folders = await _folderService.getSavedFolders();

    int totalSongsFound = 0;
    int totalFiles = 0;

    for (final folder in folders) {
      if (_isCancelled) break;

      await for (final progress in scanFolder(folder.uri, folder.displayName)) {
        totalSongsFound = progress.songsFound;
        totalFiles = progress.totalFiles;
        yield progress;
      }
    }

    yield ScanProgress(
      songsFound: totalSongsFound,
      totalFiles: totalFiles,
      isComplete: true,
    );
  }

  /// Create a SongEntity from AudioFileInfo with basic metadata.
  /// Full metadata extraction via Rust will be added in a later phase.
  SongEntity _createSongEntity(AudioFileInfo file, String folderUri) {
    final entity = SongEntity()
      ..filePath = file.uri
      ..title = _extractTitleFromFilename(file.name)
      ..artist = 'Unknown Artist'
      ..durationMs =
          0 // Will be populated by Rust metadata extraction
      ..fileType = file.extension.toUpperCase()
      ..fileSize = file.size
      ..dateAdded = DateTime.now()
      ..lastModified = DateTime.fromMillisecondsSinceEpoch(file.lastModified)
      ..folderUri = folderUri;

    return entity;
  }

  /// Extract a clean title from the filename.
  String _extractTitleFromFilename(String filename) {
    // Remove extension
    final dotIndex = filename.lastIndexOf('.');
    String name = dotIndex > 0 ? filename.substring(0, dotIndex) : filename;

    // Remove common track number patterns at the start
    // e.g., "01 - Song Name", "01. Song Name", "01_Song Name"
    name = name.replaceFirst(RegExp(r'^\d{1,3}[\s._-]+'), '');

    // Replace underscores with spaces
    name = name.replaceAll('_', ' ');

    // Trim and collapse multiple spaces
    name = name.trim().replaceAll(RegExp(r'\s+'), ' ');

    return name.isEmpty ? filename : name;
  }
}
