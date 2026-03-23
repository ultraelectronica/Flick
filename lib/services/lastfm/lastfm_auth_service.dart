import 'package:flutter/foundation.dart';
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
    debugPrint('[LastFm] getTokenAndLaunchAuth: Starting');
    
    final apiKey = await _credentials.getApiKey();
    final sharedSecret = await _credentials.getSharedSecret();
    
    debugPrint('[LastFm] getTokenAndLaunchAuth: API key length: ${apiKey?.length ?? 0}');
    debugPrint('[LastFm] getTokenAndLaunchAuth: Shared secret length: ${sharedSecret?.length ?? 0}');

    if (apiKey == null || apiKey.isEmpty) {
      debugPrint('[LastFm] getTokenAndLaunchAuth: ERROR - API key not configured');
      throw Exception(
        'Last.fm API key not configured. Please set your API key in settings.',
      );
    }
    if (sharedSecret == null || sharedSecret.isEmpty) {
      debugPrint('[LastFm] getTokenAndLaunchAuth: ERROR - Shared secret not configured');
      throw Exception(
        'Last.fm shared secret not configured. Please set your shared secret in settings.',
      );
    }

    debugPrint('[LastFm] getTokenAndLaunchAuth: Requesting token from Last.fm API');
    try {
      final data = await _client.post({'method': 'auth.getToken'});
      final token = data['token'] as String;
      debugPrint('[LastFm] getTokenAndLaunchAuth: Token received: ${token.substring(0, 8)}...');

      await _credentials.setPendingToken(token);
      debugPrint('[LastFm] getTokenAndLaunchAuth: Pending token saved');

      final authUri = Uri.parse(
        'https://www.last.fm/api/auth/'
        '?api_key=$apiKey&token=$token',
      );
      debugPrint('[LastFm] getTokenAndLaunchAuth: Auth URL: ${authUri.toString()}');

      try {
        debugPrint('[LastFm] getTokenAndLaunchAuth: Attempting to launch URL');
        final launched = await launchUrl(
          authUri,
          mode: LaunchMode.externalApplication,
        );
        debugPrint('[LastFm] getTokenAndLaunchAuth: Launch result: $launched');

        if (!launched) {
          debugPrint('[LastFm] getTokenAndLaunchAuth: ERROR - launchUrl returned false');
          // Clean up pending token if launch failed
          await _credentials.deletePendingToken();
          throw Exception('Could not launch Last.fm authorization page.');
        }
        
        debugPrint('[LastFm] getTokenAndLaunchAuth: Successfully launched browser');
      } catch (e, stackTrace) {
        debugPrint('[LastFm] getTokenAndLaunchAuth: ERROR during launch - $e');
        debugPrint('[LastFm] getTokenAndLaunchAuth: Stack trace: $stackTrace');
        // Clean up pending token on any launch error
        await _credentials.deletePendingToken();
        rethrow;
      }
    } catch (e, stackTrace) {
      debugPrint('[LastFm] getTokenAndLaunchAuth: ERROR during token request - $e');
      debugPrint('[LastFm] getTokenAndLaunchAuth: Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Step 2: Exchange pending token for a permanent session key.
  Future<LastFmSession> exchangeTokenForSession() async {
    debugPrint('[LastFm] exchangeTokenForSession: Starting');
    
    final token = await _credentials.getPendingToken();
    debugPrint('[LastFm] exchangeTokenForSession: Pending token exists: ${token != null}');
    
    if (token == null) {
      debugPrint('[LastFm] exchangeTokenForSession: ERROR - No pending token');
      throw Exception('No pending Last.fm token found. Start auth again.');
    }

    try {
      debugPrint('[LastFm] exchangeTokenForSession: Requesting session from Last.fm API');
      final data = await _client.post({
        'method': 'auth.getSession',
        'token': token,
      });

      final raw = data['session'] as Map<String, dynamic>;
      final session = LastFmSession(
        sessionKey: raw['key'] as String,
        username: raw['name'] as String,
      );
      
      debugPrint('[LastFm] exchangeTokenForSession: Session received for user: ${session.username}');

      await _credentials.setSessionKey(session.sessionKey);
      await _credentials.setUsername(session.username);
      await _credentials.deletePendingToken();
      
      debugPrint('[LastFm] exchangeTokenForSession: Session saved successfully');

      return session;
    } catch (e, stackTrace) {
      debugPrint('[LastFm] exchangeTokenForSession: ERROR - $e');
      debugPrint('[LastFm] exchangeTokenForSession: Stack trace: $stackTrace');
      // Clean up stale pending token on failure so it doesn't linger
      await _credentials.deletePendingToken();
      rethrow;
    }
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
    debugPrint('[LastFm] setApiCredentials: Saving credentials (key length: ${apiKey.length}, secret length: ${sharedSecret.length})');
    await _credentials.setApiKey(apiKey);
    await _credentials.setSharedSecret(sharedSecret);
    debugPrint('[LastFm] setApiCredentials: Credentials saved successfully');
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
