import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:calculator_messenger/core/security/encrypted_cache.dart';
import 'package:calculator_messenger/repositories/messenger_repository.dart';
import 'pin_vault_test.dart' show MemorySecrets;

Future<void> signIn(SupabaseClient client, String owner) async {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final token =
      '${part({'alg': 'HS256'})}.${part({'sub': owner, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600})}.local-adapter-test';
  await client.auth.recoverSession(
    jsonEncode({
      'access_token': token,
      'refresh_token': 'local-adapter-test',
      'token_type': 'bearer',
      'user': {
        'id': owner,
        'app_metadata': {},
        'user_metadata': {},
        'aud': 'authenticated',
        'created_at': '2026-01-01T00:00:00Z',
      },
    }),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final boundary in ['account switch', 'same-account relock']) {
    test(
      'HTTP adapter: late conversations cannot populate a new cache after $boundary',
      () async {
        final dir = await Directory.systemTemp.createTemp('cache-isolation-');
        final secrets = MemorySecrets();
        final caches = <String, EncryptedCache>{};
        final started = Completer<void>(), release = Completer<void>();
        final client = SupabaseClient(
          'https://example.invalid',
          'public-adapter-test',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) async {
            if (!started.isCompleted) started.complete();
            await release.future;
            return http.Response(
              jsonEncode([
                {
                  'id': 'old-conversation',
                  'last_body': 'account A private preview',
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
          cacheFactory: (owner) =>
              caches[owner] = EncryptedCache(owner, secrets, directory: dir),
        );
        StreamSubscription<Object?>? subscription;
        try {
          await signIn(client, 'owner-a');
          subscription = repo.conversations().listen(
            (_) {},
            onError: (Object _) {},
          );
          await started.future;
          await repo.suspend();
          final next = boundary == 'account switch' ? 'owner-b' : 'owner-a';
          if (next == 'owner-b') await signIn(client, next);
          await repo.prepare();
          final current = caches[next]!;
          release.complete();
          await Future<void>.delayed(const Duration(milliseconds: 200));
          expect(current.data['conversations'], isNull);
          final restored = EncryptedCache(next, secrets, directory: dir);
          await restored.initialize();
          expect(restored.data['conversations'], isNull);
        } finally {
          if (!release.isCompleted) release.complete();
          await subscription?.cancel();
          await repo.dispose();
          await client.dispose();
          await dir.delete(recursive: true);
        }
      },
    );
  }
  test(
    'HTTP adapter: late message page does not query another owner or write their cache',
    () async {
      final dir = await Directory.systemTemp.createTemp('message-isolation-');
      final secrets = MemorySecrets();
      final caches = <String, EncryptedCache>{};
      final started = Completer<void>(), release = Completer<void>();
      var hides = 0;
      final client = SupabaseClient(
        'https://example.invalid',
        'public-adapter-test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/message_hides')) {
            hides++;
            return http.Response(
              '[]',
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
          if (!started.isCompleted) started.complete();
          await release.future;
          return http.Response(
            jsonEncode([
              {
                'id': 'message-a',
                'conversation_id': 'chat-a',
                'sender_id': 'owner-a',
                'body': 'A private message',
                'kind': 'text',
                'created_at': DateTime.now().toUtc().toIso8601String(),
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
        cacheFactory: (owner) =>
            caches[owner] = EncryptedCache(owner, secrets, directory: dir),
      );
      StreamSubscription<Object?>? subscription;
      try {
        await signIn(client, 'owner-a');
        subscription = repo
            .messages('chat-a')
            .listen((_) {}, onError: (Object _) {});
        await started.future;
        await repo.suspend();
        await signIn(client, 'owner-b');
        await repo.prepare();
        release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(hides, 0);
        expect(caches['owner-b']!.data['messages.chat-a'], isNull);
      } finally {
        if (!release.isCompleted) release.complete();
        await subscription?.cancel();
        await repo.dispose();
        await client.dispose();
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'HTTP adapter: late hide cannot remove another account cached copy',
    () async {
      final dir = await Directory.systemTemp.createTemp('hide-isolation-');
      final secrets = MemorySecrets();
      final caches = <String, EncryptedCache>{};
      final started = Completer<void>(), release = Completer<void>();
      final client = SupabaseClient(
        'https://example.invalid',
        'public-adapter-test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          if (!started.isCompleted) started.complete();
          await release.future;
          return http.Response('', 201, request: request);
        }),
      );
      final repo = MessengerRepository(
        client,
        connectivity: const Stream.empty(),
        cacheFactory: (owner) =>
            caches[owner] = EncryptedCache(owner, secrets, directory: dir),
      );
      try {
        await signIn(client, 'owner-a');
        await repo.prepare();
        final hiding = repo.hide('shared-message');
        final rejected = expectLater(hiding, throwsStateError);
        await started.future;
        await repo.suspend();
        await signIn(client, 'owner-b');
        await repo.prepare();
        caches['owner-b']!.data['messages.shared'] = [
          {'id': 'shared-message', 'body': 'B copy'},
        ];
        release.complete();
        await rejected;
        expect((caches['owner-b']!.data['messages.shared'] as List).length, 1);
        expect(repo.isHidden('shared-message'), isFalse);
      } finally {
        if (!release.isCompleted) release.complete();
        await repo.dispose();
        await client.dispose();
        await dir.delete(recursive: true);
      }
    },
  );
}
