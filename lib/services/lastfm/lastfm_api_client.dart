import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'package:flick/services/lastfm/lastfm_credentials.dart';

/// Last.fm API constants for fallback (when user hasn't configured credentials).
class LastFmConfig {
  static const String apiKey = String.fromEnvironment(
    'LASTFM_API_KEY',
    defaultValue: '',
  );
  static const String sharedSecret = String.fromEnvironment(
    'LASTFM_SHARED_SECRET',
    defaultValue: '',
  );
  static const String baseUrl = 'https://ws.audioscrobbler.com/2.0/';
}

/// Thrown when Last.fm returns an error response body.
class LastFmApiException implements Exception {
  const LastFmApiException(this.code, this.message);

  final int code;
  final String message;

  @override
  String toString() => 'LastFmApiException($code): $message';
}

/// Low-level HTTP client for Last.fm API.
/// Handles MD5 request signing required by all write endpoints.
/// Uses user-provided API credentials if available.
class LastFmApiClient {
  LastFmApiClient({LastFmCredentials? credentials})
    : _credentials = credentials ?? LastFmCredentials();

  final LastFmCredentials _credentials;

  /// Builds the MD5 api_sig per Last.fm spec.
  String _sign(Map<String, String> params, String sharedSecret) {
    final keys = params.keys.toList()
      ..remove('format')
      ..remove('callback')
      ..sort();

    final raw =
        keys.fold<String>('', (buffer, key) => '$buffer$key${params[key]}') +
        sharedSecret;

    return md5.convert(utf8.encode(raw)).toString();
  }

  /// Gets the API key to use (user-provided or fallback).
  Future<String> _getApiKey() async {
    final userKey = await _credentials.getApiKey();
    return (userKey?.isNotEmpty ?? false) ? userKey! : LastFmConfig.apiKey;
  }

  /// Gets the shared secret to use (user-provided or fallback).
  Future<String> _getSharedSecret() async {
    final userSecret = await _credentials.getSharedSecret();
    return (userSecret?.isNotEmpty ?? false)
        ? userSecret!
        : LastFmConfig.sharedSecret;
  }

  /// Signed POST for auth/session/scrobble endpoints.
  Future<Map<String, dynamic>> post(Map<String, String> params) async {
    final apiKey = await _getApiKey();
    final sharedSecret = await _getSharedSecret();

    final body = Map<String, String>.from(params)
      ..['api_key'] = apiKey
      ..['format'] = 'json';

    body['api_sig'] = _sign(body, sharedSecret);

    final response = await http.post(
      Uri.parse(LastFmConfig.baseUrl),
      body: body,
    );

    return _parse(response);
  }

  /// Unsigned GET for public lookup endpoints.
  Future<Map<String, dynamic>> get(Map<String, String> params) async {
    final apiKey = await _getApiKey();

    final query = Map<String, String>.from(params)
      ..['api_key'] = apiKey
      ..['format'] = 'json';

    final response = await http.get(
      Uri.parse(LastFmConfig.baseUrl).replace(queryParameters: query),
    );

    return _parse(response);
  }

  Map<String, dynamic> _parse(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LastFmApiException(
        response.statusCode,
        'HTTP ${response.statusCode}: ${response.reasonPhrase}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (data.containsKey('error')) {
      throw LastFmApiException(
        data['error'] as int,
        data['message'] as String? ?? 'Unknown Last.fm error',
      );
    }

    return data;
  }
}
