import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:calculator_messenger/core/security/local_cache.dart';
import 'package:calculator_messenger/repositories/messenger_repository.dart';
import 'repository_isolation_test.dart' show signIn;

class _FailedCache implements LocalCache {
  @override
  Map<String, dynamic> data = {};
  bool cleared = false, forgotten = false;
  @override
  Future<void> initialize() async => throw StateError('Encrypted key missing');
  @override
  Future<void> save() async => throw StateError('Should not use failed cache');
  @override
  Future<void> forget() async { forgotten = true; }
  @override
  Future<void> clear() async { cleared = true; }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('unavailable encrypted cache permits online reads and confirmed text only, without clearing files', () async {
    final failed = _FailedCache();
    final sent = <Map<String, dynamic>>[];
    var online = true;
    final client = SupabaseClient('https://fixture.invalid', 'public-fixture-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        http.Response json(Object data, [int status = 200]) => http.Response(
          jsonEncode(data), status, headers: {'content-type': 'application/json'}, request: request);
        if (request.url.path.endsWith('/rpc/conversation_list')) {
          return json([{'id': 'chat', 'title': 'Private', 'archived': false}]);
        }
        if (request.url.path.endsWith('/rpc/send_message')) {
          if (!online) throw http.ClientException('offline');
          sent.add(Map<String, dynamic>.from(jsonDecode(request.body) as Map));
          return json('delivered');
        }
        throw StateError('Unexpected HTTP request');
      }));
    final repo = MessengerRepository(client, connectivity: const Stream.empty(),
      cacheFactory: (_) => failed);
    try {
      await signIn(client, 'owner-a');
      final rows = await repo.conversations().first.timeout(const Duration(seconds: 4));
      expect(rows.single['id'], 'chat');
      expect(repo.onlineOnly, isTrue);
      expect(failed.forgotten, isTrue);
      expect(failed.cleared, isFalse);
      online = false;
      await expectLater(repo.send('chat', 'please retry'), throwsStateError);
      expect(sent, isEmpty);
      online = true;
      final id = await repo.send('chat', 'please retry');
      expect(sent.single['mid'], id);
      expect(sent.single['content'], 'please retry');
      await repo.flush();
      expect(sent, hasLength(1));
      await expectLater(repo.send('chat', '', kind: 'image', attachment: {'id': 'fixture'}),
        throwsStateError);
      expect(failed.cleared, isFalse);
    } finally {
      await repo.dispose();
      await client.dispose();
    }
  });
}
