import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

// Public HTTPS gateway URL only; this class never holds a worker/server secret.
class AccountGateway {
  AccountGateway(String url, {http.Client? client})
    : _uri = Uri.parse(url),
      _http = client ?? http.Client(),
      _ownsClient = client == null {
    if (_uri.scheme != 'https' || _uri.host.isEmpty || _uri.userInfo.isNotEmpty ||
        _uri.hasQuery || _uri.hasFragment || _uri.path != '/account-auth') {
      throw const FormatException('Invalid account gateway configuration.');
    }
  }

  final Uri _uri;
  final http.Client _http;
  final bool _ownsClient;

  Future<Map<String, dynamic>> invoke(
    Map<String, dynamic> data, {String? accessToken}
  ) async {
    http.Response response;
    try {
      response = await _http.post(_uri,
        headers: {
          'content-type': 'application/json',
          if (accessToken != null) 'authorization': 'Bearer $accessToken',
        },
        body: jsonEncode(data),
      ).timeout(const Duration(seconds: 20));
    } on Exception {
      throw const FormatException('Account operation unavailable. Check your connection and try again.');
    }
    Object? decoded;
    try { decoded = jsonDecode(response.body); } on FormatException {
      throw const FormatException('Account operation unavailable. Check your connection and try again.');
    }
    if (response.statusCode == 200 && decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    final code = decoded is Map ? decoded['code'] : null;
    throw FormatException(switch (code) {
      'user_id_unavailable' => 'This User ID is unavailable.',
      'invalid_credentials' => 'User ID or password is incorrect.',
      'invalid_recovery' => 'User ID or recovery code is invalid or already used.',
      'rate_limited' => 'Too many attempts. Try again later.',
      'account_created' => 'Account created. Sign in, then save recovery codes in Settings.',
      _ => 'Account operation unavailable. Check your connection and try again.',
    });
  }

  void close() { if (_ownsClient) _http.close(); }
}
