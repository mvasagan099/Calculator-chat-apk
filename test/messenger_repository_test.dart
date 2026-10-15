import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:calculator_messenger/core/security/encrypted_cache.dart';
import 'package:calculator_messenger/models/message.dart';
import 'package:calculator_messenger/repositories/messenger_repository.dart';
import 'pin_vault_test.dart' show MemorySecrets;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('equal timestamps follow the database UUID cursor consistently', () {
    ChatMessage message(String id) => ChatMessage(
      id: id,
      conversationId: 'chat',
      senderId: 'owner',
      body: 'text',
      kind: 'text',
      createdAt: DateTime.utc(2026),
    );
    final rows = [message('001'), message('003'), message('002')]
      ..sort(ChatMessage.newestFirst);
    expect(rows.map((m) => m.id), ['003', '002', '001']);
  });

  test('database outages retry, permission and validation failures do not', () {
    for (final code in [
      '503',
      '429',
      'PGRST003',
      '08006',
      '53300',
      '40001',
      '40P01',
    ]) {
      expect(
        isRetryableMessageError(
          PostgrestException(message: 'unavailable', code: code),
        ),
        isTrue,
        reason: code,
      );
    }
    for (final code in ['42501', '23514', 'P0001', '23505']) {
      expect(
        isRetryableMessageError(
          PostgrestException(message: 'rejected', code: code),
        ),
        isFalse,
        reason: code,
      );
    }
  });

  test(
    'loaded history refreshes edits and deletions in batches scoped to the conversation',
    () async {
      final queries = <Uri>[];
      final client = SupabaseClient(
        'https://example.invalid',
        'unit-test-public-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          queries.add(request.url);
          final older = request.url.queryParameters.containsKey('id');
          return http.Response(
            jsonEncode([
              {
                'id': older ? 'old' : 'recent',
                'created_at': '2026-10-15T00:00:00Z',
                'body': older ? '' : 'recent',
                'deleted_at': older ? '2026-10-15T01:00:00Z' : null,
              },
            ]),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      final repo = MessengerRepository(
        client,
        connectivity: const Stream.empty(),
      );
      try {
        final rows = await repo.loadWindow('conversation', [
          'old',
          'recent',
          'old',
        ]);
        expect(rows.map((r) => r['id']).toSet(), {'old', 'recent'});
        expect(
          rows.singleWhere((r) => r['id'] == 'old')['deleted_at'],
          isNotNull,
        );
        expect(queries, hasLength(2));
        expect(
          queries.every(
            (q) => q.queryParameters['conversation_id'] == 'eq.conversation',
          ),
          isTrue,
        );
        expect(queries.last.queryParameters['id'], 'in.("old")');
      } finally {
        await repo.dispose();
        await client.dispose();
      }
    },
  );

  test(
    'encrypted outbox survives restart and reuses the same message ID on retry',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'messenger-outbox-',
      );
      final secrets = MemorySecrets();
      bool online = false;
      Completer<void>? pendingResponse;
      final requests = <Map<String, dynamic>>[];
      final client = SupabaseClient(
        'https://example.invalid',
        'unit-test-public-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          if (!request.url.path.endsWith('/rpc/send_message')) {
            throw StateError(
              'Unexpected network operation: ${request.url.path}',
            );
          }
          requests.add(jsonDecode(request.body) as Map<String, dynamic>);
          if (!online) throw http.ClientException('offline');
          await pendingResponse?.future;
          return http.Response(
            jsonEncode(jsonDecode(request.body)['mid']),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      String jwtPart(Object value) =>
          base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
      final token =
          '${jwtPart({'alg': 'HS256'})}.${jwtPart({'sub': 'owner', 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600})}.unit-test';
      await client.auth.recoverSession(
        jsonEncode({
          'access_token': token,
          'refresh_token': 'unit-test',
          'token_type': 'bearer',
          'user': {
            'id': 'owner',
            'app_metadata': {},
            'user_metadata': {},
            'aud': 'authenticated',
            'created_at': '2026-01-01T00:00:00Z',
          },
        }),
      );
      MessengerRepository repository() => MessengerRepository(
        client,
        cacheFactory: (owner) =>
            EncryptedCache(owner, secrets, directory: directory),
        connectivity: const Stream.empty(),
      );
      var repo = repository();
      try {
        await repo.prepare();
        await repo.setWallpaper('chat', 'dusk');
        final id = await repo.send('chat', 'survives relock and restart');
        await repo.flush();
        await repo.dispose();
        final restored = EncryptedCache('owner', secrets, directory: directory);
        await restored.initialize();
        expect((restored.data['outbox'] as List).single['id'], id);
        expect((restored.data['outbox'] as List).single['failed'], isTrue);
        expect(
          await File('${directory.path}/cache-owner.bin').readAsString(),
          isNot(contains('survives relock')),
        );
        online = true;
        repo = repository();
        await repo.prepare();
        await repo.flush();
        expect(await repo.wallpaper('chat'), 'dusk');
        expect(requests.map((r) => r['mid']).toSet(), {id});
        expect(requests.length, greaterThanOrEqualTo(2));
        final saved = EncryptedCache('owner', secrets, directory: directory);
        await saved.initialize();
        final pending = (saved.data['outbox'] as List).single;
        expect(pending['committed'], isTrue, reason: jsonEncode(pending));
        expect(pending['pending'], isFalse);
        expect(pending['failed'], isFalse);
        // A newly enqueued message must not wait for the periodic timer merely
        // because the previous send is still awaiting its network response.
        pendingResponse = Completer<void>();
        final first = await repo.send('chat', 'in flight');
        final second = await repo.send('chat', 'queued during flight');
        pendingResponse.complete();
        pendingResponse = null;
        await repo.flush();
        final drained = EncryptedCache('owner', secrets, directory: directory);
        await drained.initialize();
        final sent = (drained.data['outbox'] as List).where(
          (item) => [first, second].contains(item['id']),
        );
        expect(sent, hasLength(2));
        expect(sent.every((item) => item['committed'] == true), isTrue);
      } finally {
        await repo.dispose();
        await client.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}
