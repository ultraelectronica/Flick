import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/library_scanner_service.dart';
import '../data/repositories/folder_repository.dart';
import '../data/entities/folder_entity.dart';

/// Provider for the FolderRepository.
final folderRepositoryProvider = Provider<FolderRepository>((ref) {
  return FolderRepository();
});

/// Provider for the LibraryScannerService.
final libraryScannerServiceProvider = Provider<LibraryScannerService>((ref) {
  return LibraryScannerService();
});

/// State representing the current scan progress.
class ScanState {
  final bool isScanning;
  final int songsFound;
  final int totalFiles;
  final String? currentFile;
  final String? currentFolder;
  final String? errorMessage;

  const ScanState({
    this.isScanning = false,
    this.songsFound = 0,
    this.totalFiles = 0,
    this.currentFile,
    this.currentFolder,
    this.errorMessage,
  });

  ScanState copyWith({
    bool? isScanning,
    int? songsFound,
    int? totalFiles,
    String? currentFile,
    String? currentFolder,
    String? errorMessage,
    bool clearError = false,
    bool clearFile = false,
    bool clearFolder = false,
  }) {
    return ScanState(
      isScanning: isScanning ?? this.isScanning,
      songsFound: songsFound ?? this.songsFound,
      totalFiles: totalFiles ?? this.totalFiles,
      currentFile: clearFile ? null : (currentFile ?? this.currentFile),
      currentFolder: clearFolder ? null : (currentFolder ?? this.currentFolder),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }

  /// Progress as a percentage (0.0 to 1.0).
  double get progress {
    if (totalFiles == 0) return 0.0;
    return (songsFound / totalFiles).clamp(0.0, 1.0);
  }
}

/// Notifier for managing library scanning state.
class LibraryScannerNotifier extends Notifier<ScanState> {
  StreamSubscription<ScanProgress>? _scanSubscription;

  @override
  ScanState build() {
    // Cleanup subscription on dispose
    ref.onDispose(() {
      _scanSubscription?.cancel();
    });

    return const ScanState();
  }

  /// Scan a specific folder.
  Future<void> scanFolder(String folderUri, String displayName) async {
    if (state.isScanning) return;

    final service = ref.read(libraryScannerServiceProvider);

    state = state.copyWith(
      isScanning: true,
      songsFound: 0,
      totalFiles: 0,
      currentFolder: displayName,
      clearError: true,
    );

    try {
      await for (final progress in service.scanFolder(folderUri, displayName)) {
        state = state.copyWith(
          songsFound: progress.songsFound,
          totalFiles: progress.totalFiles,
          currentFile: progress.currentFile,
          currentFolder: progress.currentFolder,
          isScanning: !progress.isComplete,
        );
      }
    } catch (e) {
      state = state.copyWith(isScanning: false, errorMessage: e.toString());
    }
  }

  /// Scan all registered folders.
  Future<void> scanAllFolders() async {
    if (state.isScanning) return;

    final service = ref.read(libraryScannerServiceProvider);

    state = state.copyWith(
      isScanning: true,
      songsFound: 0,
      totalFiles: 0,
      clearError: true,
    );

    try {
      await for (final progress in service.scanAllFolders()) {
        state = state.copyWith(
          songsFound: progress.songsFound,
          totalFiles: progress.totalFiles,
          currentFile: progress.currentFile,
          currentFolder: progress.currentFolder,
          isScanning: !progress.isComplete,
        );
      }
    } catch (e) {
      state = state.copyWith(isScanning: false, errorMessage: e.toString());
    }
  }

  /// Cancel the current scan.
  void cancelScan() {
    final service = ref.read(libraryScannerServiceProvider);
    service.cancelScan();
    state = state.copyWith(isScanning: false);
  }

  /// Clear any error message.
  void clearError() {
    state = state.copyWith(clearError: true);
  }
}

/// Main scanner provider.
final libraryScannerProvider =
    NotifierProvider<LibraryScannerNotifier, ScanState>(
      LibraryScannerNotifier.new,
    );

/// Convenience provider for checking if scanning is in progress.
final isScanningProvider = Provider<bool>((ref) {
  return ref.watch(libraryScannerProvider.select((state) => state.isScanning));
});

// ============================================================================
// Folders providers
// ============================================================================

/// All registered music folders.
final musicFoldersProvider = FutureProvider.autoDispose<List<FolderEntity>>((
  ref,
) async {
  final repository = ref.watch(folderRepositoryProvider);
  return repository.getAllFolders();
});

/// Notifier for managing music folders.
class MusicFoldersNotifier extends AsyncNotifier<List<FolderEntity>> {
  @override
  Future<List<FolderEntity>> build() async {
    final repository = ref.watch(folderRepositoryProvider);
    return repository.getAllFolders();
  }

  /// Add a new folder.
  Future<void> addFolder(FolderEntity folder) async {
    final repository = ref.read(folderRepositoryProvider);
    await repository.upsertFolder(folder);
    ref.invalidateSelf();
  }

  /// Remove a folder.
  Future<void> removeFolder(String folderUri) async {
    final repository = ref.read(folderRepositoryProvider);
    await repository.deleteFolder(folderUri);
    ref.invalidateSelf();
  }
}

/// Notifier provider for folder management.
final musicFoldersNotifierProvider =
    AsyncNotifierProvider.autoDispose<MusicFoldersNotifier, List<FolderEntity>>(
      MusicFoldersNotifier.new,
    );
