import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flick/models/song_view_mode.dart';
import 'package:flick/services/songs_view_preference_service.dart';

final songsViewPreferenceServiceProvider = Provider<SongsViewPreferenceService>(
  (ref) {
    return SongsViewPreferenceService();
  },
);

class SongsViewModeNotifier extends Notifier<SongViewMode> {
  bool _initialized = false;

  @override
  SongViewMode build() {
    if (!_initialized) {
      _initialized = true;
      Future<void>.microtask(_loadFromPreferences);
    }
    return SongViewMode.orbit;
  }

  Future<void> _loadFromPreferences() async {
    final mode = await ref
        .read(songsViewPreferenceServiceProvider)
        .getViewMode();
    if (ref.mounted && state != mode) {
      state = mode;
    }
  }

  Future<void> setMode(SongViewMode mode) async {
    if (state == mode) return;
    state = mode;
    await ref.read(songsViewPreferenceServiceProvider).setViewMode(mode);
  }
}

final songsViewModeProvider =
    NotifierProvider<SongsViewModeNotifier, SongViewMode>(
      SongsViewModeNotifier.new,
    );
