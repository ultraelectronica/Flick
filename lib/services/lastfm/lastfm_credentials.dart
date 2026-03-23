import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Manages Last.fm API credentials and session data storage.
class LastFmCredentials {
  LastFmCredentials({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  // Storage keys
  static const _kApiKey = 'lastfm_api_key';
  static const _kSharedSecret = 'lastfm_shared_secret';
  static const _kSessionKey = 'lastfm_session_key';
  static const _kUsername = 'lastfm_username';
  static const _kPendingToken = 'lastfm_pending_token';

  // Credential setters
  Future<void> setApiKey(String apiKey) async {
    await _storage.write(key: _kApiKey, value: apiKey);
  }

  Future<void> setSharedSecret(String secret) async {
    await _storage.write(key: _kSharedSecret, value: secret);
  }

  // Credential getters
  Future<String?> getApiKey() async {
    return _storage.read(key: _kApiKey);
  }

  Future<String?> getSharedSecret() async {
    return _storage.read(key: _kSharedSecret);
  }

  bool hasValidCredentials({String? apiKey, String? sharedSecret}) {
    return apiKey != null &&
        apiKey.isNotEmpty &&
        sharedSecret != null &&
        sharedSecret.isNotEmpty;
  }

  // Session management
  Future<void> setSessionKey(String sessionKey) async {
    await _storage.write(key: _kSessionKey, value: sessionKey);
  }

  Future<String?> getSessionKey() async {
    return _storage.read(key: _kSessionKey);
  }

  Future<void> setUsername(String username) async {
    await _storage.write(key: _kUsername, value: username);
  }

  Future<String?> getUsername() async {
    return _storage.read(key: _kUsername);
  }

  // Pending token management
  Future<void> setPendingToken(String token) async {
    await _storage.write(key: _kPendingToken, value: token);
  }

  Future<String?> getPendingToken() async {
    return _storage.read(key: _kPendingToken);
  }

  Future<void> deletePendingToken() async {
    await _storage.delete(key: _kPendingToken);
  }

  // Clear all
  Future<void> clearAll() async {
    await _storage.deleteAll();
  }

  // Clear only session (keep credentials)
  Future<void> clearSession() async {
    await _storage.delete(key: _kSessionKey);
    await _storage.delete(key: _kUsername);
    await _storage.delete(key: _kPendingToken);
  }
}
