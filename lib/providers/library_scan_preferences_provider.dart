import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flick/services/library_scan_preferences_service.dart';

final libraryScanPreferencesServiceProvider =
    Provider<LibraryScanPreferencesService>((ref) {
      return LibraryScanPreferencesService();
    });

class LibraryScanPreferencesNotifier extends Notifier<LibraryScanPreferences> {
  bool _initialized = false;

  @override
  LibraryScanPreferences build() {
    if (!_initialized) {
      _initialized = true;
      Future<void>.microtask(_loadPreferences);
    }
    return const LibraryScanPreferences();
  }

  Future<void> _loadPreferences() async {
    final preferences = await ref
        .read(libraryScanPreferencesServiceProvider)
        .getPreferences();
    if (ref.mounted) {
      state = preferences;
    }
  }

  Future<void> setFilterNonMusicFilesAndFolders(bool value) async {
    if (state.filterNonMusicFilesAndFolders == value) return;
    state = state.copyWith(filterNonMusicFilesAndFolders: value);
    await ref
        .read(libraryScanPreferencesServiceProvider)
        .setFilterNonMusicFilesAndFolders(value);
  }

  Future<void> setIgnoreTracksSmallerThan500Kb(bool value) async {
    if (state.ignoreTracksSmallerThan500Kb == value) return;
    state = state.copyWith(ignoreTracksSmallerThan500Kb: value);
    await ref
        .read(libraryScanPreferencesServiceProvider)
        .setIgnoreTracksSmallerThan500Kb(value);
  }

  Future<void> setIgnoreTracksShorterThan60Seconds(bool value) async {
    if (state.ignoreTracksShorterThan60Seconds == value) return;
    state = state.copyWith(ignoreTracksShorterThan60Seconds: value);
    await ref
        .read(libraryScanPreferencesServiceProvider)
        .setIgnoreTracksShorterThan60Seconds(value);
  }

  Future<void> setCreatePlaylistsFromM3uFiles(bool value) async {
    if (state.createPlaylistsFromM3uFiles == value) return;
    state = state.copyWith(createPlaylistsFromM3uFiles: value);
    await ref
        .read(libraryScanPreferencesServiceProvider)
        .setCreatePlaylistsFromM3uFiles(value);
  }
}

final libraryScanPreferencesProvider =
    NotifierProvider<LibraryScanPreferencesNotifier, LibraryScanPreferences>(
      LibraryScanPreferencesNotifier.new,
    );
