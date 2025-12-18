import 'package:isar_community/isar.dart';

part 'song_entity.g.dart';

/// Database entity for storing song metadata.
@collection
class SongEntity {
  Id id = Isar.autoIncrement;

  /// File path or content URI for the song
  @Index(unique: true)
  late String filePath;

  /// Title of the song
  @Index()
  late String title;

  /// Artist name
  @Index()
  late String artist;

  /// Album name
  @Index()
  String? album;

  /// Album artist
  String? albumArtist;

  /// Duration in milliseconds
  int? durationMs;

  /// Track number
  int? trackNumber;

  /// Disc number
  int? discNumber;

  /// Year of release
  int? year;

  /// Genre
  @Index()
  String? genre;

  /// File size in bytes
  int? fileSize;

  /// File type (e.g., mp3, flac, wav)
  String? fileType;

  /// Bitrate in kbps
  int? bitrate;

  /// Sample rate in Hz
  int? sampleRate;

  /// Number of audio channels
  int? channels;

  /// Bit depth
  int? bitDepth;

  /// Path to album art (if extracted)
  String? albumArtPath;

  /// URI of the folder containing this song
  String? folderUri;

  /// Date the song was added to the library
  late DateTime dateAdded;

  /// Last time metadata was updated
  DateTime? lastModified;
}
