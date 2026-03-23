import 'package:url_launcher/url_launcher.dart';

import 'package:flick/services/lastfm/lastfm_api_client.dart';
import 'package:flick/services/lastfm/lastfm_models.dart';
import 'package:flick/services/lastfm/lastfm_credentials.dart';

/// Manages the Last.fm web auth flow and persists the session key securely.
class LastFmAuthService {
  LastFmAuthService({LastFmApiClient? client, LastFmCredentials? credentials})
    : _client = client ?? LastFmApiClient(),
      _credentials = credentials ?? LastFmCredentials();

  final LastFmApiClient _client;
  final LastFmCredentials _credentials;

  /// Step 1: Request a token and open the Last.fm authorization page.
  /// Requires API key and shared secret to be set first.
  Future<void> getTokenAndLaunchAuth() async {
    final apiKey = await _credentials.getApiKey();

    if (apiKey == null || apiKey.isEmpty) {
      throw Exception(
        'Last.fm API key not configured. Please set your API key in settings.',
      );
    }

    final data = await _client.post({'method': 'auth.getToken'});
    final token = data['token'] as String;

    await _credentials.setPendingToken(token);

    final authUri = Uri.parse(
      'https://www.last.fm/api/auth/'
      '?api_key=$apiKey&token=$token',
    );

    final launched = await launchUrl(
      authUri,
      mode: LaunchMode.externalApplication,
    );

    if (!launched) {
      throw Exception('Could not launch Last.fm authorization page.');
    }
  }

  /// Step 2: Exchange pending token for a permanent session key.
  Future<LastFmSession> exchangeTokenForSession() async {
    final token = await _credentials.getPendingToken();
    if (token == null) {
      throw Exception('No pending Last.fm token found. Start auth again.');
    }

    final data = await _client.post({
      'method': 'auth.getSession',
      'token': token,
    });

    final raw = data['session'] as Map<String, dynamic>;
    final session = LastFmSession(
      sessionKey: raw['key'] as String,
      username: raw['name'] as String,
    );

    await _credentials.setSessionKey(session.sessionKey);
    await _credentials.setUsername(session.username);
    await _credentials.deletePendingToken();

    return session;
  }

  Future<LastFmSession?> getSession() async {
    final sessionKey = await _credentials.getSessionKey();
    final username = await _credentials.getUsername();

    if (sessionKey == null || username == null) {
      return null;
    }

    return LastFmSession(sessionKey: sessionKey, username: username);
  }

  Future<bool> isConnected() async {
    return (await getSession()) != null;
  }

  /// Clears session data (disconnect/logout) but keeps API credentials.
  Future<void> disconnect() async {
    await _credentials.clearSession();
  }

  /// Sets the API key and shared secret for the current user.
  Future<void> setApiCredentials(String apiKey, String sharedSecret) async {
    await _credentials.setApiKey(apiKey);
    await _credentials.setSharedSecret(sharedSecret);
  }

  /// Gets both API key and shared secret.
  Future<({String? apiKey, String? sharedSecret})> getApiCredentials() async {
    return (
      apiKey: await _credentials.getApiKey(),
      sharedSecret: await _credentials.getSharedSecret(),
    );
  }

  /// Checks if API credentials are configured.
  Future<bool> hasValidApiCredentials() async {
    final apiKey = await _credentials.getApiKey();
    final sharedSecret = await _credentials.getSharedSecret();
    return _credentials.hasValidCredentials(
      apiKey: apiKey,
      sharedSecret: sharedSecret,
    );
  }
}
