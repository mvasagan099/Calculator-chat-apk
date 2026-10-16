import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'local_cache.dart';
import 'local_retention.dart';
import 'pin_vault.dart';

List<int> _rowAad(String owner, String id) =>
    utf8.encode('calculator-sqlite:v1:$owner:$id');

Future<Map<String, dynamic>> _decryptLegacy(
  String encoded,
  List<int> material,
  String owner,
) => Isolate.run(() async {
  final envelope = jsonDecode(encoded) as Map;
  final plain = await AesGcm.with256bits().decrypt(
    SecretBox(
      base64Decode(envelope['data']),
      nonce: base64Decode(envelope['nonce']),
      mac: Mac(base64Decode(envelope['mac'])),
    ),
    secretKey: SecretKey(material),
    aad: utf8.encode(owner),
  );
  return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
});

// Pass only plain data/key bytes, never a live SQLite handle, across isolates.
Future<List<Map<String, Object?>>> _encryptRows(
  Map<String, String> entries,
  List<int> material,
  String owner,
) => Isolate.run(() async {
  final cipher = AesGcm.with256bits(), key = SecretKey(material);
  final result = <Map<String, Object?>>[];
  for (final entry in entries.entries) {
    final box = await cipher.encrypt(
      utf8.encode(entry.value),
      secretKey: key,
      aad: _rowAad(owner, entry.key),
    );
    result.add({
      'id': entry.key,
      'nonce': Uint8List.fromList(box.nonce),
      'payload': Uint8List.fromList(box.cipherText),
      'tag': Uint8List.fromList(box.mac.bytes),
    });
  }
  return result;
});

Future<List<({String id, String plain, Map<String, dynamic> value})>>
_decryptRows(
  List<Map<String, Object?>> rows,
  List<int> material,
  String owner,
) => Isolate.run(() async {
  final cipher = AesGcm.with256bits(), key = SecretKey(material);
  final result = <({String id, String plain, Map<String, dynamic> value})>[];
  for (final row in rows) {
    final id = row['id'] as String;
    final plain = utf8.decode(
      await cipher.decrypt(
        SecretBox(
          row['payload'] as Uint8List,
          nonce: row['nonce'] as Uint8List,
          mac: Mac(row['tag'] as Uint8List),
        ),
        secretKey: key,
        aad: _rowAad(owner, id),
      ),
    );
    result.add((
      id: id,
      plain: plain,
      value: jsonDecode(plain) as Map<String, dynamic>,
    ));
  }
  return result;
});

/// Transactional encrypted collections, not a plaintext message/FTS database.
/// SQLite headers/counts/sizes remain visible. Supabase remains authoritative.
class SqliteEncryptedCache implements LocalCache {
  SqliteEncryptedCache(
    this.userId,
    this.store, {
    this.directory,
    DatabaseFactory? factory,
    DateTime Function()? clock,
  }) : factory = factory ?? databaseFactory,
       clock = clock ?? DateTime.now;

  final String userId;
  final SecretStore store;
  final Directory? directory;
  final DatabaseFactory factory;
  final DateTime Function() clock;
  final _cipher = AesGcm.with256bits();
  final _hmac = Hmac.sha256();
  SecretKey? _key, _indexKey;
  Database? _db;
  String? _path;
  String? _legacyDigest;
  bool _closing = false;
  Future<void> _writes = Future.value();
  final _persisted = <String, String>{};
  @override
  Map<String, dynamic> data = {};

  Future<String> _location() async {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(userId)) {
      throw StateError('Invalid cache owner');
    }
    final root = directory ?? await getApplicationSupportDirectory();
    await root.create(recursive: true);
    return '${root.path}/cache-$userId.sqlite';
  }

  Future<String> _id(String domain) async => base64UrlEncode(
    (await _hmac.calculateMac(
      utf8.encode(domain),
      secretKey: _indexKey!,
    )).bytes,
  ).replaceAll('=', '');

  @override
  Future<void> initialize() async {
    if (_db != null) return;
    _closing = false;
    _path = await _location();
    final legacy = File(_path!.replaceFirst(RegExp(r'\.sqlite$'), '.bin'));
    try {
      var raw = await store.read('cache.key.$userId');
      if (raw == null) {
        if (await File(_path!).exists() || await legacy.exists()) {
          throw StateError('Local encryption key unavailable');
        }
        raw = base64Encode(await (await _cipher.newSecretKey()).extractBytes());
        await store.write('cache.key.$userId', raw);
      }
      final bytes = base64Decode(raw);
      if (bytes.length != 32) {
        throw StateError('Local encryption key unavailable');
      }
      _key = SecretKey(bytes);
      _indexKey = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: _key!,
        nonce: utf8.encode(userId),
        info: utf8.encode('calculator-sqlite-index:v1'),
      );
      _db = await factory.openDatabase(
        _path!,
        options: OpenDatabaseOptions(
          version: 1,
          singleInstance: false,
          onConfigure: (db) async {
            await db.rawQuery('PRAGMA journal_mode=WAL');
            await db.execute('PRAGMA synchronous=FULL');
            await db.execute('PRAGMA secure_delete=ON');
          },
          onCreate: (db, _) async {
            await db.execute(
              'CREATE TABLE cache_entries (id TEXT PRIMARY KEY, nonce BLOB NOT NULL, payload BLOB NOT NULL, tag BLOB NOT NULL) WITHOUT ROWID',
            );
            await db.execute(
              'CREATE TABLE cache_meta (id INTEGER PRIMARY KEY CHECK(id=1), initialized INTEGER NOT NULL CHECK(initialized IN (0,1)), legacy_digest TEXT)',
            );
            await db.insert('cache_meta', {'id': 1, 'initialized': 0});
          },
        ),
      );
      final meta = await _db!.query(
        'cache_meta',
        where: 'id = ?',
        whereArgs: [1],
      );
      _legacyDigest = meta.single['legacy_digest'] as String?;
      if (meta.single['initialized'] == 0) {
        if ((await _db!.query(
          'cache_entries',
          columns: ['id'],
          limit: 1,
        )).isNotEmpty) {
          throw StateError('Inconsistent local migration metadata');
        }
        // Strict legacy read: do not overwrite a corrupt/undecryptable outbox.
        if (await legacy.exists()) {
          _legacyDigest = base64Encode(
            (await Sha256().hash(await legacy.readAsBytes())).bytes,
          );
          data = await _readLegacy(legacy);
        }
        await save(); // Collections + initialized marker commit atomically.
        final restored = await _load();
        if (jsonEncode(restored) != jsonEncode(data)) {
          throw StateError('Local cache migration verification failed');
        }
        if (await legacy.exists()) await legacy.delete();
      } else {
        data = await _load();
        // A crash after commit but before deleting v1 must not replay it.
        if (await legacy.exists()) {
          final digest = base64Encode(
            (await Sha256().hash(await legacy.readAsBytes())).bytes,
          );
          if (digest != _legacyDigest) {
            throw StateError('A changed legacy cache requires recovery review');
          }
          await legacy.delete();
        }
      }
      pruneLocalData(data, clock());
      await save(); // No transaction if retention and data are unchanged.
    } catch (_) {
      await _db?.close();
      _db = null;
      _key = null;
      _indexKey = null;
      _persisted.clear();
      data = {};
      throw StateError(
        'Encrypted local cache is unavailable; existing files were preserved',
      );
    }
  }

  Future<Map<String, dynamic>> _readLegacy(File file) async {
    final result = await _decryptLegacy(
      await file.readAsString(),
      await _key!.extractBytes(),
      userId,
    );
    pruneLocalData(result, clock());
    return result;
  }

  Future<Map<String, dynamic>> _load() async {
    final rows = await _db!.query('cache_entries');
    final decoded = <String, Map<String, dynamic>>{};
    _persisted.clear();
    for (final row in await _decryptRows(
      rows,
      await _key!.extractBytes(),
      userId,
    )) {
      decoded[row.id] = row.value;
      _persisted[row.id] = row.plain;
    }
    final rootId = await _id('root');
    final root = decoded.remove(rootId)!;
    final sections = (root['sections'] as List).cast<String>();
    if (sections.toSet().length != sections.length ||
        sections.length != decoded.length) {
      throw StateError('Incomplete local cache');
    }
    final result = <String, dynamic>{};
    for (final id in sections) {
      final row = decoded[id]!;
      final key = row['key'] as String;
      if (await _id('section:$key') != id) {
        throw StateError('Invalid local cache binding');
      }
      result[key] = row['value'];
    }
    return result;
  }

  @override
  Future<void> save() {
    if (_closing || _db == null || _key == null) {
      return Future.error(StateError('Local cache is closed'));
    }
    pruneLocalData(data, clock());
    // Snapshot synchronously before any await; later UI mutations cannot alter
    // an earlier queued transaction. Only changed collections are encrypted.
    final snapshot = {for (final e in data.entries) e.key: jsonEncode(e.value)};
    _writes = _writes.catchError((Object _) {}).then((_) async {
      final entries = <String, String>{};
      for (final entry in snapshot.entries) {
        // Value was already encoded at snapshot time. Do not decode/re-encode
        // thousands of unchanged messages on the UI isolate.
        entries[await _id('section:${entry.key}')] =
            '{"key":${jsonEncode(entry.key)},"value":${entry.value}}';
      }
      entries[await _id('root')] = jsonEncode({
        'sections': entries.keys.toList(),
      });
      final dirty = {
        for (final entry in entries.entries)
          if (_persisted[entry.key] != entry.value) entry.key: entry.value,
      };
      final removed = _persisted.keys
          .where((key) => !entries.containsKey(key))
          .toList();
      if (dirty.isEmpty && removed.isEmpty) return;
      final changed = await _encryptRows(
        dirty,
        await _key!.extractBytes(),
        userId,
      );
      await _db!.transaction((txn) async {
        final batch = txn.batch();
        for (final row in changed) {
          batch.insert(
            'cache_entries',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        for (final id in removed) {
          batch.delete('cache_entries', where: 'id = ?', whereArgs: [id]);
        }
        batch.update(
          'cache_meta',
          {'initialized': 1, 'legacy_digest': _legacyDigest},
          where: 'id = ?',
          whereArgs: [1],
        );
        await batch.commit(noResult: true);
      });
      _persisted
        ..clear()
        ..addAll(entries);
    });
    return _writes;
  }

  @override
  Future<void> forget() async {
    _closing = true;
    await _writes.catchError((Object _) {});
    await _db?.close();
    _db = null;
    _key = null;
    _indexKey = null;
    _legacyDigest = null;
    _persisted.clear();
    data = {};
  }

  @override
  Future<void> clear() async {
    await forget();
    final path = _path ?? await _location();
    await factory.deleteDatabase(path);
    for (final suffix in ['.bin', '.bin.tmp']) {
      final legacy = File(path.replaceFirst(RegExp(r'\.sqlite$'), suffix));
      if (await legacy.exists()) await legacy.delete();
    }
    await store.delete('cache.key.$userId');
  }
}
