import 'sqlite_test_factory.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:calculator_messenger/core/security/sqlite_cache.dart';
import 'package:calculator_messenger/repositories/messenger_repository.dart';
import 'pin_vault_test.dart' show MemorySecrets;
import 'repository_isolation_test.dart' show signIn;

class GatedSecrets extends MemorySecrets {
  final started = Completer<void>(), release = Completer<void>();
  bool gated = true;
  @override
  Future<String?> read(String key) async {
    if (gated && key == 'cache.key.owner-a') {
      started.complete();
      await release.future;
      gated = false;
    }
    return super.read(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real SQLite: concurrent opens share one cache and account replacement closes the old handle',
    () async {
      final dir = await Directory.systemTemp.createTemp('sqlite-lifecycle-');
      final secrets = MemorySecrets();
      final caches = <String, SqliteEncryptedCache>{};
      final counts = <String, int>{};
      final client = SupabaseClient(
        'https://example.invalid',
        'public-adapter',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      final repository = MessengerRepository(
        client,
        connectivity: const Stream.empty(),
        cacheFactory: (owner) {
          counts[owner] = (counts[owner] ?? 0) + 1;
          return caches[owner] = SqliteEncryptedCache(
            owner,
            secrets,
            directory: dir,
            factory: sqliteTestFactory,
          );
        },
      );
      try {
        await signIn(client, 'owner-a');
        await Future.wait(List.generate(3, (_) => repository.prepare()));
        expect(counts['owner-a'], 1);
        caches['owner-a']!.data['private'] = 'A data';
        await caches['owner-a']!.save();
        await signIn(client, 'owner-b');
        await Future.wait(List.generate(3, (_) => repository.prepare()));
        expect(counts['owner-b'], 1);
        expect(caches['owner-a']!.data, isEmpty);
        await expectLater(caches['owner-a']!.save(), throwsStateError);
        expect(caches['owner-b']!.data['private'], isNull);
      } finally {
        await repository.dispose();
        await client.dispose();
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'real SQLite + HTTP adapter: offline outbox retries the same ID after repository restart',
    () async {
      final dir = await Directory.systemTemp.createTemp('sqlite-outbox-');
      final secrets = MemorySecrets();
      var online = false;
      final sentIds = <String>[];
      final client = SupabaseClient(
        'https://example.invalid',
        'public-adapter',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          expect(request.url.path, endsWith('/rpc/send_message'));
          final id = jsonDecode(request.body)['mid'] as String;
          sentIds.add(id);
          if (!online) throw http.ClientException('offline');
          return http.Response(
            jsonEncode(id),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      SqliteEncryptedCache cache(String owner) => SqliteEncryptedCache(
        owner,
        secrets,
        directory: dir,
        factory: sqliteTestFactory,
      );
      MessengerRepository repo() => MessengerRepository(
        client,
        connectivity: const Stream.empty(),
        cacheFactory: cache,
      );
      await signIn(client, 'owner-a');
      var repository = repo();
      try {
        final id = await repository.send('chat', 'offline message');
        await repository.flush();
        await repository.dispose();
        final stored = cache('owner-a');
        await stored.initialize();
        expect(stored.data['outbox'].single['id'], id);
        expect(stored.data['outbox'].single['failed'], isTrue);
        await stored.forget();
        repository = repo();
        online = true;
        await repository.prepare();
        await repository.flush();
        await repository.suspend();
        final restored = cache('owner-a');
        await restored.initialize();
        expect(restored.data['outbox'].single['committed'], isTrue);
        expect(sentIds, isNotEmpty);
        expect(sentIds.toSet(), {id});
        await restored.forget();
      } finally {
        await repository.dispose();
        await client.dispose();
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'real SQLite: changing accounts during startup cannot enqueue the old screen text',
    () async {
      final dir = await Directory.systemTemp.createTemp('sqlite-startup-');
      final secrets = GatedSecrets();
      var requests = 0;
      final client = SupabaseClient(
        'https://example.invalid',
        'public-adapter',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          requests++;
          return http.Response('null', 200);
        }),
      );
      SqliteEncryptedCache cache(String owner) => SqliteEncryptedCache(
        owner,
        secrets,
        directory: dir,
        factory: sqliteTestFactory,
      );
      final repository = MessengerRepository(
        client,
        connectivity: const Stream.empty(),
        cacheFactory: cache,
      );
      try {
        await signIn(client, 'owner-a');
        final pending = repository.send('chat', 'account A private text');
        final failure = expectLater(pending, throwsStateError);
        await secrets.started.future;
        await signIn(client, 'owner-b');
        secrets.release.complete();
        await failure;
        await repository.prepare();
        await repository.suspend();
        final bob = cache('owner-b');
        await bob.initialize();
        expect(bob.data['outbox'], isNull);
        expect(requests, 0);
        await bob.forget();
      } finally {
        if (!secrets.release.isCompleted) secrets.release.complete();
        await repository.dispose();
        await client.dispose();
        await dir.delete(recursive: true);
      }
    },
  );
}
