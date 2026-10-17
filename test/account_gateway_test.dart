import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:calculator_messenger/core/services/account_gateway.dart';

void main() {
  test('gateway never sends a privileged secret or caller-supplied IP', () async {
    final client = MockClient((request) async {
      expect(request.url.toString(), 'https://gateway.workers.dev/account-auth');
      expect(request.headers['x-account-gateway-secret'], isNull);
      expect(request.headers['x-trusted-account-ip'], isNull);
      expect(request.headers['authorization'], 'Bearer fixture-token');
      expect(jsonDecode(request.body)['user_id'], 'chosen_id');
      return http.Response('{"refresh_token":"fixture","user_uuid":"00000000-0000-0000-0000-000000000000"}', 200,
        headers: {'content-type': 'application/json'});
    });
    final gateway = AccountGateway('https://gateway.workers.dev/account-auth', client: client);
    final response = await gateway.invoke({'action': 'login', 'user_id': 'chosen_id'}, accessToken: 'fixture-token');
    expect(response['refresh_token'], 'fixture');
    gateway.close();
    client.close();
  });

  test('provider failures do not reveal private server errors', () async {
    final client = MockClient((_) async => http.Response('{"error":"private provider details"}', 503,
      headers: {'content-type': 'application/json'}));
    final gateway = AccountGateway('https://gateway.workers.dev/account-auth', client: client);
    await expectLater(gateway.invoke({'action': 'login'}), throwsA(isA<FormatException>().having(
      (e) => e.message, 'error', 'Account operation unavailable. Check your connection and try again.')));
    client.close();
  });

  test('rejects non-HTTPS and credential-bearing gateway URLs', () {
    for (final url in ['http://gateway.workers.dev/account-auth',
      'https://user:secret@gateway.workers.dev/account-auth',
      'https://gateway.workers.dev/account-auth?secret=bad',
      'https://gateway.workers.dev/other']) {
      expect(() => AccountGateway(url), throwsFormatException);
    }
  });
}
