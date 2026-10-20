import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:calculator_messenger/core/security/vault_service.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'sqlite_test_factory.dart';

class TestAndroidDatabaseException implements DatabaseException {
  TestAndroidDatabaseException(this._message);
  final String _message;
  @override
  String toString() => 'DatabaseException($_message)';
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Decorator that simulates Android native SQLiteDatabase behavior where
/// [SQLiteDatabase.execSQL] rejects PRAGMA queries that return results:
/// "Queries can be performed using SQLiteDatabase query or rawQuery methods only."
class AndroidEmulatingDatabase implements Database {
  AndroidEmulatingDatabase(this._inner);
  final Database _inner;

  int executePragmaCalls = 0;
  int rawQueryPragmaCalls = 0;

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    final trimmed = sql.trim().toUpperCase();
    if (trimmed.startsWith('PRAGMA') && trimmed.contains('SECURE_DELETE')) {
      executePragmaCalls++;
      throw TestAndroidDatabaseException(
        'unknown error (code 0 SQLITE_OK): Queries can be performed using SQLiteDatabase query or rawQuery methods only.',
      );
    }
    return _inner.execute(sql, arguments);
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? arguments]) {
    final trimmed = sql.trim().toUpperCase();
    if (trimmed.startsWith('PRAGMA') && trimmed.contains('SECURE_DELETE')) {
      rawQueryPragmaCalls++;
    }
    return _inner.rawQuery(sql, arguments);
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) => _inner.query(
    table,
    distinct: distinct,
    columns: columns,
    where: where,
    whereArgs: whereArgs,
    groupBy: groupBy,
    having: having,
    orderBy: orderBy,
    limit: limit,
    offset: offset,
  );

  @override
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action, {bool? exclusive}) =>
      _inner.transaction(action, exclusive: exclusive);

  @override
  Future<void> close() => _inner.close();

  @override
  String get path => _inner.path;

  @override
  bool get isOpen => _inner.isOpen;

  @override
  Batch batch() => _inner.batch();

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      _inner.delete(table, where: where, whereArgs: whereArgs);

  @override
  Future<int> insert(String table, Map<String, Object?> values,
          {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) =>
      _inner.insert(table, values,
          nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);

  @override
  Future<int> update(String table, Map<String, Object?> values,
          {String? where, List<Object?>? whereArgs, ConflictAlgorithm? conflictAlgorithm}) =>
      _inner.update(table, values,
          where: where, whereArgs: whereArgs, conflictAlgorithm: conflictAlgorithm);

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) =>
      _inner.rawDelete(sql, arguments);

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) =>
      _inner.rawInsert(sql, arguments);

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) =>
      _inner.rawUpdate(sql, arguments);

  @override
  Database get database => this;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class AndroidEmulatingDatabaseFactory implements DatabaseFactory {
  AndroidEmulatingDatabaseFactory(this._underlying);
  final DatabaseFactory _underlying;
  AndroidEmulatingDatabase? lastDatabase;

  @override
  Future<Database> openDatabase(String path, {OpenDatabaseOptions? options}) async {
    final configuredOptions = OpenDatabaseOptions(
      version: options?.version,
      onConfigure: options?.onConfigure != null
          ? (db) {
              final wrapped = lastDatabase = AndroidEmulatingDatabase(db);
              return options!.onConfigure!(wrapped);
            }
          : null,
      onCreate: options?.onCreate != null
          ? (db, v) {
              final wrapped = lastDatabase ??= AndroidEmulatingDatabase(db);
              return options!.onCreate!(wrapped, v);
            }
          : null,
      onUpgrade: options?.onUpgrade != null
          ? (db, oldV, newV) {
              final wrapped = lastDatabase ??= AndroidEmulatingDatabase(db);
              return options!.onUpgrade!(wrapped, oldV, newV);
            }
          : null,
      onDowngrade: options?.onDowngrade != null
          ? (db, oldV, newV) {
              final wrapped = lastDatabase ??= AndroidEmulatingDatabase(db);
              return options!.onDowngrade!(wrapped, oldV, newV);
            }
          : null,
      onOpen: options?.onOpen != null
          ? (db) {
              final wrapped = lastDatabase ??= AndroidEmulatingDatabase(db);
              return options!.onOpen!(wrapped);
            }
          : null,
      readOnly: options?.readOnly ?? false,
      singleInstance: options?.singleInstance ?? true,
    );

    final realDb = await _underlying.openDatabase(path, options: configuredOptions);
    return lastDatabase ??= AndroidEmulatingDatabase(realDb);
  }

  @override
  Future<void> deleteDatabase(String path) => _underlying.deleteDatabase(path);

  @override
  Future<bool> databaseExists(String path) => _underlying.databaseExists(path);

  @override
  Future<String> getDatabasesPath() => _underlying.getDatabasesPath();

  @override
  Future<void> setDatabasesPath(String path) => _underlying.setDatabasesPath(path);

  @override
  Future<Uint8List> readDatabaseBytes(String path) =>
      _underlying.readDatabaseBytes(path);

  @override
  Future<void> writeDatabaseBytes(String path, Uint8List bytes) =>
      _underlying.writeDatabaseBytes(path, bytes);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<void> _safeDeleteDir(Directory dir) async {
  for (var i = 0; i < 5; i++) {
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      return;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final key = SecretKey(List<int>.filled(32, 42));

  group('Private Vault Android SQLite PRAGMA & Initialization Regression Tests', () {
    test('PRAGMA secure_delete=ON succeeds via rawQuery on Android-emulated SQLiteDatabase', () async {
      final root = await Directory.systemTemp.createTemp('vault-android-pragma-pass');
      try {
        final emulatingFactory = AndroidEmulatingDatabaseFactory(sqliteTestFactory);
        final vault = VaultService(
          customDir: root,
          customKey: key,
          factory: emulatingFactory,
        );

        // Vault initialization must succeed without throwing "Queries can be performed using SQLiteDatabase..."
        await vault.initialize();

        expect(emulatingFactory.lastDatabase, isNotNull);
        expect(emulatingFactory.lastDatabase!.rawQueryPragmaCalls, greaterThan(0),
            reason: 'PRAGMA secure_delete must be routed through rawQuery');
        expect(emulatingFactory.lastDatabase!.executePragmaCalls, equals(0),
            reason: 'PRAGMA secure_delete must not be routed through execSQL');

        // Verify standard operations work
        final item = await vault.importBytes(
          bytes: Uint8List.fromList(utf8.encode('vault content after pragma fix')),
          filename: 'test_file.txt',
          folder: 'Personal',
        );
        expect(item.filename, 'test_file.txt');

        final decrypted = utf8.decode(await vault.readDecryptedBytes(item));
        expect(decrypted, 'vault content after pragma fix');

        await vault.close();
      } finally {
        await _safeDeleteDir(root);
      }
    });

    test('reopening existing encrypted vault succeeds and preserves files', () async {
      final root = await Directory.systemTemp.createTemp('vault-reopen-test');
      try {
        final emulatingFactory = AndroidEmulatingDatabaseFactory(sqliteTestFactory);
        final vault1 = VaultService(
          customDir: root,
          customKey: key,
          factory: emulatingFactory,
        );
        await vault1.initialize();

        final item = await vault1.importBytes(
          bytes: Uint8List.fromList(utf8.encode('persistent secret 123')),
          filename: 'doc.pdf',
          folder: 'Financial',
        );
        await vault1.close();

        // Ensure encrypted file exists on disk
        final encFile = File('${root.path}/${item.encryptedFilename}');
        expect(await encFile.exists(), isTrue);
        final rawBytes = await encFile.readAsBytes();
        expect(utf8.decode(rawBytes, allowMalformed: true), isNot(contains('persistent secret 123')));

        // Reopen in a second session
        final vault2 = VaultService(
          customDir: root,
          customKey: key,
          factory: emulatingFactory,
        );
        await vault2.initialize();

        expect(vault2.items, hasLength(1));
        expect(vault2.items.single.filename, 'doc.pdf');
        expect(vault2.items.single.folder, 'Financial');
        final recovered = utf8.decode(await vault2.readDecryptedBytes(vault2.items.single));
        expect(recovered, 'persistent secret 123');

        await vault2.close();
      } finally {
        await _safeDeleteDir(root);
      }
    });

    test('unsupported pragma engine fallback safely ignores error and preserves vault initialization', () async {
      final root = await Directory.systemTemp.createTemp('vault-pragma-fallback');
      try {
        // Factory where both rawQuery and execute reject secure_delete (e.g. read-only or stripped embedded SQLite)
        final failingPragmaDbFactory = _FailingPragmaFactory(sqliteTestFactory);
        final vault = VaultService(
          customDir: root,
          customKey: key,
          factory: failingPragmaDbFactory,
        );

        // Initialization must still succeed safely; optional defense-in-depth pragma does not block access
        await vault.initialize();
        expect(vault.folders, contains('Root'));
        await vault.close();
      } finally {
        await _safeDeleteDir(root);
      }
    });

    test('retry after a recoverable error opens the vault without losing existing files', () async {
      final root = await Directory.systemTemp.createTemp('vault-retry-recover');
      try {
        // Step 1: Populate vault with an item
        final normalVault = VaultService(
          customDir: root,
          customKey: key,
          factory: sqliteTestFactory,
        );
        await normalVault.initialize();
        final item = await normalVault.importBytes(
          bytes: Uint8List.fromList(utf8.encode('survives failure')),
          filename: 'important.txt',
        );
        await normalVault.close();

        final encFile = File('${root.path}/${item.encryptedFilename}');
        expect(await encFile.exists(), isTrue);

        // Step 2: Attempt opening with an unavailable database factory (simulating transient locked state)
        final lockedFactory = _LockedDatabaseFactory();
        final failingVault = VaultService(
          customDir: root,
          customKey: key,
          factory: lockedFactory,
        );

        await expectLater(
          failingVault.initialize(),
          throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Private vault could not open locally. Existing encrypted files are preserved'),
          )),
        );

        // Verify encrypted files were NOT erased by the failed open attempt
        expect(await encFile.exists(), isTrue);

        // Step 3: Retry with healthy factory (as the UI "Retry opening vault" button does)
        final recoveredVault = VaultService(
          customDir: root,
          customKey: key,
          factory: sqliteTestFactory,
        );
        await recoveredVault.initialize();

        expect(recoveredVault.items, hasLength(1));
        expect(recoveredVault.items.single.filename, 'important.txt');
        expect(
          utf8.decode(await recoveredVault.readDecryptedBytes(recoveredVault.items.single)),
          'survives failure',
        );
        await recoveredVault.close();
      } finally {
        await _safeDeleteDir(root);
      }
    });

    test('proves PRAGMA secure_delete=ON fails on execSQL but succeeds on rawQuery', () async {
      final root = await Directory.systemTemp.createTemp('vault-pragma-comparison');
      try {
        final emulatingFactory = AndroidEmulatingDatabaseFactory(sqliteTestFactory);
        final db = await emulatingFactory.openDatabase('${root.path}/test_db.sqlite');

        // Direct execute (execSQL) throws the Android query exception
        expect(
          () => db.execute('PRAGMA secure_delete=ON'),
          throwsA(isA<DatabaseException>().having(
            (e) => e.toString(),
            'message',
            contains('Queries can be performed using SQLiteDatabase query or rawQuery methods only'),
          )),
        );

        // rawQuery succeeds without exception
        final results = await db.rawQuery('PRAGMA secure_delete=ON');
        expect(results, isNotNull);

        await db.close();
      } finally {
        await _safeDeleteDir(root);
      }
    });
  });
}

class _FailingPragmaFactory implements DatabaseFactory {
  _FailingPragmaFactory(this._underlying);
  final DatabaseFactory _underlying;

  @override
  Future<Database> openDatabase(String path, {OpenDatabaseOptions? options}) =>
      _underlying.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: options?.version,
          onConfigure: options?.onConfigure != null
              ? (db) => options!.onConfigure!(_RejectAllPragmaDb(db))
              : null,
          onCreate: options?.onCreate,
          onUpgrade: options?.onUpgrade,
          singleInstance: options?.singleInstance,
        ),
      );

  @override
  Future<void> deleteDatabase(String path) => _underlying.deleteDatabase(path);
  @override
  Future<bool> databaseExists(String path) => _underlying.databaseExists(path);
  @override
  Future<String> getDatabasesPath() => _underlying.getDatabasesPath();
  @override
  Future<void> setDatabasesPath(String path) => _underlying.setDatabasesPath(path);
  @override
  Future<Uint8List> readDatabaseBytes(String path) => _underlying.readDatabaseBytes(path);
  @override
  Future<void> writeDatabaseBytes(String path, Uint8List bytes) => _underlying.writeDatabaseBytes(path, bytes);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _RejectAllPragmaDb implements Database {
  _RejectAllPragmaDb(this._inner);
  final Database _inner;

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    if (sql.toUpperCase().contains('PRAGMA')) {
      throw TestAndroidDatabaseException('PRAGMA not supported on this engine');
    }
    return _inner.execute(sql, arguments);
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? arguments]) async {
    if (sql.toUpperCase().contains('PRAGMA')) {
      throw TestAndroidDatabaseException('PRAGMA not supported on this engine');
    }
    return _inner.rawQuery(sql, arguments);
  }

  @override
  Future<List<Map<String, Object?>>> query(String table, {bool? distinct, List<String>? columns, String? where, List<Object?>? whereArgs, String? groupBy, String? having, String? orderBy, int? limit, int? offset}) =>
      _inner.query(table, distinct: distinct, columns: columns, where: where, whereArgs: whereArgs, groupBy: groupBy, having: having, orderBy: orderBy, limit: limit, offset: offset);

  @override
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action, {bool? exclusive}) =>
      _inner.transaction(action, exclusive: exclusive);

  @override
  Future<void> close() => _inner.close();
  @override
  String get path => _inner.path;
  @override
  bool get isOpen => _inner.isOpen;
  @override
  Batch batch() => _inner.batch();
  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) => _inner.delete(table, where: where, whereArgs: whereArgs);
  @override
  Future<int> insert(String table, Map<String, Object?> values, {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) => _inner.insert(table, values, nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);
  @override
  Future<int> update(String table, Map<String, Object?> values, {String? where, List<Object?>? whereArgs, ConflictAlgorithm? conflictAlgorithm}) => _inner.update(table, values, where: where, whereArgs: whereArgs, conflictAlgorithm: conflictAlgorithm);
  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) => _inner.rawDelete(sql, arguments);
  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) => _inner.rawInsert(sql, arguments);
  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) => _inner.rawUpdate(sql, arguments);
  @override
  Database get database => this;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _LockedDatabaseFactory implements DatabaseFactory {
  @override
  Future<Database> openDatabase(String path, {OpenDatabaseOptions? options}) async {
    throw TestAndroidDatabaseException('Database locked: unable to obtain lock');
  }

  @override
  Future<void> deleteDatabase(String path) async {}
  @override
  Future<bool> databaseExists(String path) async => false;
  @override
  Future<String> getDatabasesPath() async => '';
  @override
  Future<void> setDatabasesPath(String path) async {}
  @override
  Future<Uint8List> readDatabaseBytes(String path) => throw UnimplementedError();
  @override
  Future<void> writeDatabaseBytes(String path, Uint8List bytes) => throw UnimplementedError();
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
