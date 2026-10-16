import '../test/sqlite_test_factory.dart';
// Explicit desktop storage benchmark. Never reads owner data or credentials.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:calculator_messenger/core/security/encrypted_cache.dart';
import 'package:calculator_messenger/core/security/local_cache.dart';
import 'package:calculator_messenger/core/security/sqlite_cache.dart';
import '../test/pin_vault_test.dart' show MemorySecrets;

Map<String, dynamic> synthetic() => {
  for (var chat = 0; chat < 20; chat++)
    'messages.chat$chat': [
      for (var row = 0; row < 200; row++)
        {
          'id': '$chat-$row',
          'conversation_id': 'chat$chat',
          'sender_id': 'synthetic',
          'kind': 'text',
          'created_at': '2026-01-01T00:00:00Z',
          'body': List.filled(32, 'benchmark data ').join(),
        },
    ],
  'outbox': [],
};

void main() {
  test(
    'compare real local encrypted storage using 20 chats x 200 messages',
    () async {
      for (final sqlite in [false, true]) {
        final dir = await Directory.systemTemp.createTemp('storage-benchmark-');
        final secrets = MemorySecrets();
        LocalCache open() => sqlite
            ? SqliteEncryptedCache(
                'synthetic',
                secrets,
                directory: dir,
                factory: sqliteTestFactory,
              )
            : EncryptedCache('synthetic', secrets, directory: dir);
        var cache = open();
        try {
          await cache.initialize();
          cache.data.addAll(synthetic());
          await cache.save();
          final updates = <int>[], unchanged = <int>[];
          for (var i = 0; i < 3; i++) {
            cache.data['messages.chat0'][0]['body'] = 'changed $i';
            final watch = Stopwatch()..start();
            await cache.save();
            updates.add(watch.elapsedMicroseconds);
          }
          for (var i = 0; i < 3; i++) {
            final watch = Stopwatch()..start();
            await cache.save();
            unchanged.add(watch.elapsedMicroseconds);
          }
          await cache.forget();
          cache = open();
          final watch = Stopwatch()..start();
          await cache.initialize();
          final restore = watch.elapsedMicroseconds;
          expect(cache.data['messages.chat0'][0]['body'], 'changed 2');
          stdout.writeln(
            'CACHE_BENCHMARK ${jsonEncode({'scope': 'desktop Flutter JIT, real files/SQLite, memory key-store adapter', 'implementation': sqlite ? 'encrypted-sqlite-collections' : 'legacy-encrypted-json-file', 'chats': 20, 'messages_per_chat': 200, 'update_us': updates, 'unchanged_save_us': unchanged, 'restore_us': restore})}',
          );
        } finally {
          await cache.forget();
          await dir.delete(recursive: true);
        }
      }
    },
  );
}
