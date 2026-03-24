import 'dart:async';
import 'package:flutter/foundation.dart';
import 'library_scanner_service.dart';
import '../data/repositories/folder_repository.dart';

/// Service for automatically syncing library changes in the background.
class AutoLibrarySyncService {
  final LibraryScannerService _scannerService;
  final FolderRepository _folderRepository;
  
  Timer? _syncTimer;
  bool _isRunning = false;
  bool _isSyncing = false;
  
  // Configurable sync interval (default: 5 minutes)
  Duration syncInterval = const Duration(minutes: 5);
  
  AutoLibrarySyncService({
    LibraryScannerService? scannerService,
    FolderRepository? folderRepository,
  })  : _scannerService = scannerService ?? LibraryScannerService(),
        _folderRepository = folderRepository ?? FolderRepository();

  /// Start automatic library syncing.
  void start() {
    if (_isRunning) return;
    
    _isRunning = true;
    debugPrint('Auto library sync started (interval: ${syncInterval.inMinutes} minutes)');
    
    _syncTimer = Timer.periodic(syncInterval, (_) => _performSync());
  }

  /// Stop automatic library syncing.
  void stop() {
    _syncTimer?.cancel();
    _syncTimer = null;
    _isRunning = false;
    debugPrint('Auto library sync stopped');
  }

  /// Manually trigger a sync.
  Future<void> syncNow() async {
    await _performSync();
  }

  Future<void> _performSync() async {
    if (_isSyncing) {
      debugPrint('Sync already in progress, skipping...');
      return;
    }

    _isSyncing = true;
    debugPrint('Starting automatic library sync...');

    try {
      final folders = await _folderRepository.getAllFolders();
      
      if (folders.isEmpty) {
        debugPrint('No folders to sync');
        return;
      }

      int totalNewSongs = 0;
      int totalDeletedSongs = 0;

      for (final folder in folders) {
        final initialCount = folder.songCount;
        
        await for (final progress in _scannerService.scanFolder(
          folder.uri,
          folder.displayName,
        )) {
          if (progress.isComplete) {
            final newCount = progress.songsFound;
            final diff = newCount - initialCount;
            
            if (diff > 0) {
              totalNewSongs += diff;
              debugPrint('Found $diff new songs in ${folder.displayName}');
            } else if (diff < 0) {
              totalDeletedSongs += diff.abs();
              debugPrint('Removed ${diff.abs()} songs from ${folder.displayName}');
            }
          }
        }
      }

      if (totalNewSongs > 0 || totalDeletedSongs > 0) {
        debugPrint(
          'Sync complete: +$totalNewSongs new, -$totalDeletedSongs removed',
        );
      } else {
        debugPrint('Sync complete: No changes detected');
      }
    } catch (e) {
      debugPrint('Error during automatic sync: $e');
    } finally {
      _isSyncing = false;
    }
  }

  bool get isRunning => _isRunning;
  bool get isSyncing => _isSyncing;
}
