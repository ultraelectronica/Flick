/// Song library display mode used across Songs UI and persistence.
enum SongViewMode { orbit, list }

extension SongViewModeX on SongViewMode {
  String get storageValue {
    switch (this) {
      case SongViewMode.orbit:
        return 'orbit';
      case SongViewMode.list:
        return 'list';
    }
  }

  String get menuLabel {
    switch (this) {
      case SongViewMode.orbit:
        return 'Orbital';
      case SongViewMode.list:
        return 'List';
    }
  }

  static SongViewMode fromStorageValue(String? value) {
    switch (value) {
      case 'list':
        return SongViewMode.list;
      case 'orbit':
      default:
        return SongViewMode.orbit;
    }
  }
}
