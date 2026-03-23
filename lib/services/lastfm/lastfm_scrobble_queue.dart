import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flick/services/lastfm/lastfm_models.dart';
import 'package:flick/services/lastfm/lastfm_scrobble_service.dart';

/// Offline-safe scrobble queue persisted in SharedPreferences.
class LastFmScrobbleQueue {
  LastFmScrobbleQueue({LastFmScrobbleService? service})
    : _service = service ?? LastFmScrobbleService();

  final LastFmScrobbleService _service;
  static const _kQueueKey = 'lastfm_scrobble_queue_v1';

  Future<void> enqueue(ScrobbleEntry entry) async {
    final queue = await _load();
    queue.add(entry.toJson());
    debugPrint(
      '[LastFm] queue enqueue artist="${entry.artist}" track="${entry.track}" pending=${queue.length}',
    );
    await _save(queue);
  }

  /// Attempts to flush all queued scrobbles.
  /// Keeps queue intact on failure for future retries.
  Future<void> flush() async {
    final raw = await _load();
    if (raw.isEmpty) {
      debugPrint('[LastFm] queue flush skipped: empty');
      return;
    }

    debugPrint('[LastFm] queue flush start pending=${raw.length}');

    final entries = raw
        .map(
          (entry) =>
              ScrobbleEntry.fromJson(Map<String, dynamic>.from(entry as Map)),
        )
        .toList();

    try {
      await _service.scrobbleBatch(entries);
      await _clear();
      debugPrint('[LastFm] queue flush success; queue cleared');
    } catch (_) {
      debugPrint('[LastFm] queue flush failed; queue retained');
      rethrow;
    }
  }

  Future<int> get pendingCount async {
    return (await _load()).length;
  }

  Future<List<dynamic>> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kQueueKey);
    if (raw == null) {
      return [];
    }
    return jsonDecode(raw) as List<dynamic>;
  }

  Future<void> _save(List<dynamic> queue) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kQueueKey, jsonEncode(queue));
  }

  Future<void> _clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kQueueKey);
  }
}
