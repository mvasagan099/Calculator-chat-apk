import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:calculator_messenger/core/security/vault_service.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'sqlite_test_factory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final key = SecretKey(List<int>.filled(32, 17));

  test('vault imports only locally; encrypted SQLite index and file survive restart', () async {
    final root = await Directory.systemTemp.createTemp('vault-sqlite-roundtrip');
    try {
      final original = File('${root.path}/source.txt');
      await original.writeAsString('private test content');
      final vault = VaultService(
        customDir: root,
        customKey: key,
        factory: sqliteTestFactory,
      );
      await vault.initialize();
      await vault.addFolder('Personal notes');
      final item = await vault.importFile(
        file: original,
        folder: 'Personal notes',
      );
      expect(await original.exists(), isTrue); // Import is a copy, not destructive.
      expect(item.folder, 'Personal notes');
      expect(utf8.decode(await vault.readDecryptedBytes(item)), 'private test content');
      final ciphertext = File('${root.path}/${item.encryptedFilename}');
      expect(await ciphertext.exists(), isTrue);
      expect(utf8.decode(await ciphertext.readAsBytes(), allowMalformed: true),
          isNot(contains('private test content')));
      await vault.renameItem(item.id, 'renamed.txt');
      await vault.close();

      final reopened = VaultService(
        customDir: root,
        customKey: key,
        factory: sqliteTestFactory,
      );
      await reopened.initialize();
      expect(reopened.folders, contains('Personal notes'));
      expect(reopened.items, hasLength(1));
      expect(reopened.items.single.filename, 'renamed.txt');
      expect(utf8.decode(await reopened.readDecryptedBytes(reopened.items.single)),
          'private test content');
      await reopened.moveItem(item.id, 'Work');
      await reopened.close();

      final again = VaultService(customDir: root, customKey: key, factory: sqliteTestFactory);
      await again.initialize();
      expect(again.items.single.folder, 'Work');
      await again.deleteItem(item.id);
      expect(again.items, isEmpty);
      expect(await ciphertext.exists(), isFalse);
      await again.close();

      final index = File('${root.path}/vault_index.sqlite');
      expect(await index.exists(), isTrue);
      final dbContents = utf8.decode(await index.readAsBytes(), allowMalformed: true);
      expect(dbContents, isNot(contains('renamed.txt')));
      expect(dbContents, isNot(contains('Personal notes')));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('legacy encrypted manifest migrates to SQLite without changing file ciphertext', () async {
    final root = await Directory.systemTemp.createTemp('vault-legacy-migration');
    try {
      final id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
      final item = VaultItem(
        id: id,
        filename: 'legacy.pdf',
        folder: 'Personal',
        category: VaultCategory.documents,
        sizeBytes: 7,
        createdAt: DateTime.utc(2026, 10, 18),
        encryptedFilename: '$id.enc',
      );
      final aes = AesGcm.with256bits();
      final fileBox = await aes.encrypt(utf8.encode('pdf-text'), secretKey: key);
      final ciphertext = Uint8List.fromList([
        ...fileBox.nonce, ...fileBox.cipherText, ...fileBox.mac.bytes,
      ]);
      await File('${root.path}/$id.enc').writeAsBytes(ciphertext);
      final manifest = jsonEncode({
        'items': [item.toJson()],
        'folders': ['Root', 'Personal', 'Work', 'Financial'],
      });
      final box = await aes.encrypt(utf8.encode(manifest), secretKey: key);
      await File('${root.path}/vault_manifest.enc').writeAsBytes([
        ...box.nonce, ...box.cipherText, ...box.mac.bytes,
      ]);

      final vault = VaultService(customDir: root, customKey: key, factory: sqliteTestFactory);
      await vault.initialize();
      expect(vault.items, hasLength(1));
      expect(vault.items.single.filename, 'legacy.pdf');
      expect(utf8.decode(await vault.readDecryptedBytes(vault.items.single)), 'pdf-text');
      expect(await File('${root.path}/vault_manifest.enc').exists(), isFalse);
      expect(await File('${root.path}/vault_index.sqlite').exists(), isTrue);
      expect(await File('${root.path}/$id.enc').readAsBytes(), ciphertext);
      await vault.close();
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('lost local vault key fails closed and does not erase ciphertext', () async {
    final root = await Directory.systemTemp.createTemp('vault-lost-key');
    try {
      final first = VaultService(customDir: root, factory: sqliteTestFactory);
      final item = await first.importBytes(
        bytes: Uint8List.fromList([10, 20, 30]),
        filename: 'secrets.bin',
      );
      await first.close();
      final ciphertext = File('${root.path}/${item.encryptedFilename}');
      final before = await ciphertext.readAsBytes();
      await File('${root.path}/vault_device.key').delete();
      final reopened = VaultService(customDir: root, factory: sqliteTestFactory);
      await expectLater(reopened.initialize(), throwsA(isA<StateError>()));
      expect(await ciphertext.readAsBytes(), before);
      expect(await File('${root.path}/vault_index.sqlite').exists(), isTrue);
      expect(await File('${root.path}/vault_device.key').exists(), isFalse);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('tampered encrypted SQLite metadata cannot be silently reset', () async {
    final root = await Directory.systemTemp.createTemp('vault-tamper');
    try {
      final first = VaultService(customDir: root, customKey: key, factory: sqliteTestFactory);
      final item = await first.importBytes(
        bytes: Uint8List.fromList([1, 2, 3]),
        filename: 'photo.jpg',
      );
      await first.close();
      final db = await sqliteTestFactory.openDatabase(
        '${root.path}/vault_index.sqlite',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await db.update('vault_state', {'tag': Uint8List(16)}, where: 'id = ?', whereArgs: [1]);
      await db.close();
      final second = VaultService(customDir: root, customKey: key, factory: sqliteTestFactory);
      await expectLater(second.initialize(), throwsA(isA<StateError>()));
      expect(await File('${root.path}/${item.encryptedFilename}').exists(), isTrue);
    } finally {
      await root.delete(recursive: true);
    }
  });
}
