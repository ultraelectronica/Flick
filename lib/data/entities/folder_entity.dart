import 'package:isar_community/isar.dart';

part 'folder_entity.g.dart';

/// Database entity for storing watched music folders.
@collection
class FolderEntity {
  Id id = Isar.autoIncrement;

  /// Content URI for the folder (SAF tree URI)
  @Index(unique: true)
  late String uri;

  /// Display name of the folder
  late String displayName;

  /// Date the folder was added to the library
  late DateTime dateAdded;

  /// Last time the folder was scanned
  DateTime? lastScanned;

  /// Number of songs found in this folder
  int songCount = 0;
}
