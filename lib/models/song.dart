/// Song data model for Flick Player.
class Song {
  /// Unique identifier for the song
  final String id;

  /// Song title
  final String title;

  /// Artist name
  final String artist;

  /// Path or URL to album art (nullable if no art available)
  final String? albumArt;

  /// Duration of the song
  final Duration duration;

  /// File type/codec (e.g., "FLAC", "MP3", "WAV", "AAC")
  final String fileType;

  /// Audio resolution (e.g., "24-bit/96kHz", "16-bit/44.1kHz")
  final String? resolution;

  /// Album name (optional)
  final String? album;

  /// File path on device
  final String? filePath;

  const Song({
    required this.id,
    required this.title,
    required this.artist,
    this.albumArt,
    required this.duration,
    required this.fileType,
    this.resolution,
    this.album,
    this.filePath,
  });

  /// Format duration as mm:ss or hh:mm:ss
  String get formattedDuration {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  /// Create a copy with modified fields
  Song copyWith({
    String? id,
    String? title,
    String? artist,
    String? albumArt,
    Duration? duration,
    String? fileType,
    String? resolution,
    String? album,
    String? filePath,
  }) {
    return Song(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      albumArt: albumArt ?? this.albumArt,
      duration: duration ?? this.duration,
      fileType: fileType ?? this.fileType,
      resolution: resolution ?? this.resolution,
      album: album ?? this.album,
      filePath: filePath ?? this.filePath,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Song && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() {
    return 'Song(id: $id, title: $title, artist: $artist)';
  }

  /// Sample songs for UI development and testing
  static List<Song> get sampleSongs => [
    const Song(
      id: '1',
      title: 'Midnight Dreams',
      artist: 'Aurora Sounds',
      duration: Duration(minutes: 4, seconds: 32),
      fileType: 'FLAC',
      resolution: '24-bit/96kHz',
      album: 'Nocturnal',
    ),
    const Song(
      id: '2',
      title: 'Electric Sunset',
      artist: 'Neon Pulse',
      duration: Duration(minutes: 3, seconds: 45),
      fileType: 'MP3',
      resolution: '320kbps',
      album: 'Synthwave City',
    ),
    const Song(
      id: '3',
      title: 'Ocean Waves',
      artist: 'Calm Frequencies',
      duration: Duration(minutes: 5, seconds: 18),
      fileType: 'FLAC',
      resolution: '16-bit/44.1kHz',
      album: 'Nature Ambient',
    ),
    const Song(
      id: '4',
      title: 'Starlight Serenade',
      artist: 'Cosmic Orchestra',
      duration: Duration(minutes: 6, seconds: 02),
      fileType: 'WAV',
      resolution: '32-bit/192kHz',
      album: 'Space Odyssey',
    ),
    const Song(
      id: '5',
      title: 'Urban Echoes',
      artist: 'City Beats',
      duration: Duration(minutes: 3, seconds: 21),
      fileType: 'AAC',
      resolution: '256kbps',
      album: 'Metropolitan',
    ),
    const Song(
      id: '6',
      title: 'Velvet Noir',
      artist: 'Shadow Jazz',
      duration: Duration(minutes: 4, seconds: 55),
      fileType: 'FLAC',
      resolution: '24-bit/48kHz',
      album: 'Late Night Sessions',
    ),
    const Song(
      id: '7',
      title: 'Crystal Caverns',
      artist: 'Ethereal Tones',
      duration: Duration(minutes: 7, seconds: 12),
      fileType: 'FLAC',
      resolution: '24-bit/96kHz',
      album: 'Deep Earth',
    ),
    const Song(
      id: '8',
      title: 'Neon Nights',
      artist: 'Retro Future',
      duration: Duration(minutes: 4, seconds: 08),
      fileType: 'MP3',
      resolution: '320kbps',
      album: '1984',
    ),
    const Song(
      id: '9',
      title: 'Whispered Secrets',
      artist: 'ASMR Dreams',
      duration: Duration(minutes: 8, seconds: 45),
      fileType: 'WAV',
      resolution: '24-bit/48kHz',
      album: 'Whisper World',
    ),
    const Song(
      id: '10',
      title: 'Thunder Road',
      artist: 'Storm Chasers',
      duration: Duration(minutes: 5, seconds: 33),
      fileType: 'FLAC',
      resolution: '16-bit/44.1kHz',
      album: 'Wild Weather',
    ),
  ];
}
