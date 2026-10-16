import 'sqlite_test_factory.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:calculator_messenger/core/security/encrypted_cache.dart';
import 'package:calculator_messenger/core/security/sqlite_cache.dart';
import 'pin_vault_test.dart' show MemorySecrets;

void main() {
  late Directory directory;
  late MemorySecrets secrets;
  final opened = <SqliteEncryptedCache>[];
  SqliteEncryptedCache cache([String owner = 'alice']) {
    final value = SqliteEncryptedCache(
      owner,
      secrets,
      directory: directory,
      factory: sqliteTestFactory,
    );
    opened.add(value);
    return value;
  }

  Future<Map<String, List<int>>> payloads() async {
    final db = await sqliteTestFactory.openDatabase(
      '${directory.path}/cache-alice.sqlite',
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      return {
        for (final r in await db.query('cache_entries'))
          r['id'] as String: r['payload'] as List<int>,
      };
    } finally {
      await db.close();
    }
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sqlite-private-');
    secrets = MemorySecrets();
  });
  tearDown(() async {
    for (final value in opened) {
      await value.forget();
    }
    opened.clear();
    await directory.delete(recursive: true);
  });

  test(
    'real SQLite persists encrypted collections/outbox and forget releases memory',
    () async {
      final first = cache();
      await first.initialize();
      first.data['messages.private-conversation'] = [
        {'id': 'stable-message', 'body': 'private message words'},
      ];
      first.data['outbox'] = [
        {'id': 'stable-pending', 'body': 'offline pending words'},
      ];
      await first.save();
      for (final file in directory.listSync().whereType<File>()) {
        final disk = latin1.decode(await file.readAsBytes());
        for (final private in [
          'private message words',
          'offline pending words',
          'private-conversation',
          'stable-pending',
        ]) {
          expect(disk, isNot(contains(private)));
        }
      }
      await first.forget();
      expect(first.data, isEmpty);
      final second = cache();
      await second.initialize();
      expect(second.data['outbox'][0]['id'], 'stable-pending');
      expect(
        second.data['messages.private-conversation'][0]['body'],
        'private message words',
      );
    },
  );

  test(
    'unchanged saves do not rewrite ciphertext; changing one collection writes only one row',
    () async {
      final value = cache();
      await value.initialize();
      value.data.addAll({
        'messages.one': [
          {'id': 'one'},
        ],
        'messages.two': [
          {'id': 'two'},
        ],
        'outbox': [],
      });
      await value.save();
      final before = await payloads();
      await value.save();
      expect(await payloads(), before);
      value.data['messages.one'] = [
        {'id': 'one', 'body': 'edited'},
      ];
      await value.save();
      final after = await payloads();
      expect(after.keys, unorderedEquals(before.keys));
      expect(
        after.keys.where(
          (id) => base64Encode(after[id]!) != base64Encode(before[id]!),
        ),
        hasLength(1),
      );
    },
  );

  test('queued SQL transactions retain the newest outbox snapshot', () async {
    final value = cache();
    await value.initialize();
    value.data['outbox'] = [
      {'id': 'a'},
    ];
    final a = value.save();
    value.data['outbox'] = [
      {'id': 'a'},
      {'id': 'b'},
    ];
    final b = value.save();
    await Future.wait([a, b]);
    await value.forget();
    final restored = cache();
    await restored.initialize();
    expect(restored.data['outbox'].map((e) => e['id']), ['a', 'b']);
  });

  test(
    'legacy migration preserves pending IDs/settings before retiring the old file',
    () async {
      final legacy = EncryptedCache('alice', secrets, directory: directory);
      await legacy.initialize();
      legacy.data.addAll({
        'outbox': [
          {'id': 'original-id', 'body': 'unsent'},
        ],
        'wallpaper.chat': 'dusk',
      });
      await legacy.save();
      final key = secrets.values['cache.key.alice'];
      await legacy.forget();
      final migrated = cache();
      await migrated.initialize();
      expect(migrated.data['outbox'][0]['id'], 'original-id');
      expect(migrated.data['wallpaper.chat'], 'dusk');
      expect(secrets.values['cache.key.alice'], key);
      expect(await File('${directory.path}/cache-alice.bin').exists(), isFalse);
      await migrated.forget();
      final again = cache();
      await again.initialize();
      expect(again.data['outbox'][0]['id'], 'original-id');
    },
  );

  test(
    'corrupt legacy cache fails closed and remains recoverable on disk',
    () async {
      final legacy = EncryptedCache('alice', secrets, directory: directory);
      await legacy.initialize();
      await legacy.forget();
      final file = File('${directory.path}/cache-alice.bin');
      await file.writeAsString('corrupt-owner-file');
      final value = cache();
      await expectLater(value.initialize(), throwsStateError);
      expect(value.data, isEmpty);
      expect(await file.readAsString(), 'corrupt-owner-file');
    },
  );

  test(
    'leftover imported file is retired without resurrecting removed pending messages',
    () async {
      final legacy = EncryptedCache('alice', secrets, directory: directory);
      await legacy.initialize();
      legacy.data['outbox'] = [
        {'id': 'old-pending'},
      ];
      await legacy.save();
      final file = File('${directory.path}/cache-alice.bin');
      final oldBytes = await file.readAsBytes();
      await legacy.forget();
      final value = cache();
      await value.initialize();
      value.data['outbox'] = [];
      await value.save();
      await value.forget();
      await file.writeAsBytes(
        oldBytes,
      ); // Simulate crash-leftover original file.
      final restored = cache();
      await restored.initialize();
      expect(restored.data['outbox'], isEmpty);
      expect(await file.exists(), isFalse);
    },
  );

  test(
    'a changed legacy outbox after a downgrade is preserved for recovery',
    () async {
      final legacy = EncryptedCache('alice', secrets, directory: directory);
      await legacy.initialize();
      legacy.data['outbox'] = [
        {'id': 'old'},
      ];
      await legacy.save();
      await legacy.forget();
      final value = cache();
      await value.initialize();
      await value.forget();
      await legacy.initialize();
      legacy.data['outbox'] = [
        {'id': 'newer-after-downgrade'},
      ];
      await legacy.save();
      await legacy.forget();
      final restored = cache();
      await expectLater(restored.initialize(), throwsStateError);
      expect(await File('${directory.path}/cache-alice.bin').exists(), isTrue);
      await legacy.initialize();
      expect(legacy.data['outbox'][0]['id'], 'newer-after-downgrade');
      await legacy.forget();
    },
  );

  test(
    'a failed SQLite transaction leaves the previous durable outbox intact',
    () async {
      final value = cache();
      await value.initialize();
      value.data['outbox'] = [
        {'id': 'durable'},
      ];
      await value.save();
      final db = await sqliteTestFactory.openDatabase(
        '${directory.path}/cache-alice.sqlite',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      try {
        await db.execute(
          "CREATE TRIGGER reject_cache_write BEFORE INSERT ON cache_entries BEGIN SELECT RAISE(ABORT, 'injected'); END",
        );
        value.data['outbox'] = [
          {'id': 'new'},
        ];
        await expectLater(value.save(), throwsA(anything));
        final restored = cache();
        await restored.initialize();
        expect(restored.data['outbox'][0]['id'], 'durable');
        await restored.forget();
        await db.execute('DROP TRIGGER reject_cache_write');
        await value.save();
      } finally {
        await db.close();
      }
    },
  );

  test(
    'untrusted migration metadata cannot overwrite committed collections',
    () async {
      final value = cache();
      await value.initialize();
      value.data['outbox'] = [
        {'id': 'preserve-this-message'},
      ];
      await value.save();
      await value.forget();
      final before = await payloads();
      final db = await sqliteTestFactory.openDatabase(
        '${directory.path}/cache-alice.sqlite',
      );
      await db.update('cache_meta', {'initialized': 0});
      await db.close();
      await expectLater(cache().initialize(), throwsStateError);
      expect(await payloads(), before);
    },
  );

  test('ciphertext tampering cannot return partial plaintext', () async {
    final value = cache();
    await value.initialize();
    value.data['secret'] = 'private';
    await value.save();
    await value.forget();
    final db = await sqliteTestFactory.openDatabase(
      '${directory.path}/cache-alice.sqlite',
    );
    await db.update('cache_entries', {
      'payload': Uint8List.fromList([1, 2, 3]),
    });
    await db.close();
    final restored = cache();
    await expectLater(restored.initialize(), throwsStateError);
    expect(restored.data, isEmpty);
  });

  test(
    'copied database cannot be opened under another account, even with a copied key',
    () async {
      final alice = cache();
      await alice.initialize();
      alice.data['secret'] = 'private';
      await alice.save();
      await alice.forget();
      await File(
        '${directory.path}/cache-alice.sqlite',
      ).copy('${directory.path}/cache-bob.sqlite');
      secrets.values['cache.key.bob'] = secrets.values['cache.key.alice']!;
      final bob = cache('bob');
      await expectLater(bob.initialize(), throwsStateError);
      expect(bob.data, isEmpty);
    },
  );

  test('clear deletes SQLite/legacy data and key after a relock', () async {
    final value = cache();
    await value.initialize();
    value.data['outbox'] = ['secret'];
    await value.save();
    await value.forget();
    await value.clear();
    expect(secrets.values['cache.key.alice'], isNull);
    expect(
      await File('${directory.path}/cache-alice.sqlite').exists(),
      isFalse,
    );
    expect(
      await File('${directory.path}/cache-alice.sqlite-wal').exists(),
      isFalse,
    );
  });
}
