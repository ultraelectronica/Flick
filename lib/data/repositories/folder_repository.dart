import 'package:isar_community/isar.dart';

import '../database.dart';

/// Repository for folder CRUD operations.
class FolderRepository {
  final Isar _isar;

  FolderRepository({Isar? isar}) : _isar = isar ?? Database.instance;

  /// Get all watched folders.
  Future<List<FolderEntity>> getAllFolders() async {
    return await _isar.folderEntitys.where().findAll();
  }

  /// Get a folder by URI.
  Future<FolderEntity?> getFolderByUri(String uri) async {
    return await _isar.folderEntitys.filter().uriEqualTo(uri).findFirst();
  }

  /// Add or update a folder.
  Future<void> upsertFolder(FolderEntity entity) async {
    await _isar.writeTxn(() async {
      // Check if folder with same URI exists
      final existing = await _isar.folderEntitys
          .filter()
          .uriEqualTo(entity.uri)
          .findFirst();

      if (existing != null) {
        entity.id = existing.id;
      }

      await _isar.folderEntitys.put(entity);
    });
  }

  /// Update the last scanned time and song count for a folder.
  Future<void> updateFolderScanInfo(String uri, int songCount) async {
    await _isar.writeTxn(() async {
      final folder = await _isar.folderEntitys
          .filter()
          .uriEqualTo(uri)
          .findFirst();

      if (folder != null) {
        folder.lastScanned = DateTime.now();
        folder.songCount = songCount;
        await _isar.folderEntitys.put(folder);
      }
    });
  }

  /// Delete a folder by URI.
  Future<void> deleteFolder(String uri) async {
    await _isar.writeTxn(() async {
      await _isar.folderEntitys.filter().uriEqualTo(uri).deleteAll();
    });
  }

  /// Delete all folders.
  Future<void> deleteAllFolders() async {
    await _isar.writeTxn(() async {
      await _isar.folderEntitys.clear();
    });
  }

  /// Watch for changes in the folders collection.
  Stream<void> watchFolders() {
    return _isar.folderEntitys.watchLazy();
  }
}
