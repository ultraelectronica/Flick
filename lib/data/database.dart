import 'package:isar_community/isar.dart';
import 'package:path_provider/path_provider.dart';

import 'entities/song_entity.dart';
import 'entities/folder_entity.dart';

export 'entities/song_entity.dart';
export 'entities/folder_entity.dart';

/// Database singleton for Isar operations.
class Database {
  static Isar? _instance;

  static Isar get instance {
    if (_instance == null) {
      throw StateError('Database not initialized. Call Database.init() first.');
    }
    return _instance!;
  }

  /// Initialize the database. Should be called once at app startup.
  static Future<void> init() async {
    if (_instance != null) return;

    final dir = await getApplicationDocumentsDirectory();
    _instance = await Isar.open(
      [SongEntitySchema, FolderEntitySchema],
      directory: dir.path,
      name: 'flick_player',
    );
  }

  /// Close the database connection.
  static Future<void> close() async {
    await _instance?.close();
    _instance = null;
  }

  /// Get the songs collection.
  static IsarCollection<SongEntity> get songs => instance.songEntitys;

  /// Get the folders collection.
  static IsarCollection<FolderEntity> get folders => instance.folderEntitys;
}
