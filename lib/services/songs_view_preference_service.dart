import 'package:shared_preferences/shared_preferences.dart';

import 'package:flick/models/song_view_mode.dart';

class SongsViewPreferenceService {
  static const _keySongViewMode = 'songs_view_mode';

  Future<SongViewMode> getViewMode() async {
    final prefs = await SharedPreferences.getInstance();
    return SongViewModeX.fromStorageValue(prefs.getString(_keySongViewMode));
  }

  Future<void> setViewMode(SongViewMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySongViewMode, mode.storageValue);
  }
}
