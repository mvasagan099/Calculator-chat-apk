// Run on real Android device or emulator to verify native Android SQLite
// database initialization and PRAGMA secure_delete compatibility.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:calculator_messenger/core/security/vault_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android real SQLite native driver opens vault without PRAGMA secure_delete exception',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp('vault-device-probe-');
      try {
        // VaultService with no custom factory uses default databaseFactory (sqflite on Android)
        var vault = VaultService(customDir: directory);

        // This triggers onConfigure -> PRAGMA secure_delete=ON via rawQuery
        await vault.initialize();

        expect(vault.folders, contains('Root'));
        expect(vault.items, isEmpty);

        // Verify importing and encrypting on Android
        final payload = 'Android native SQLite secret ${DateTime.now().toIso8601String()}';
        final item = await vault.importBytes(
          bytes: Uint8List.fromList(utf8.encode(payload)),
          filename: 'device_test.txt',
          folder: 'Personal',
        );

        expect(item.filename, 'device_test.txt');
        expect(item.folder, 'Personal');

        // Verify encrypted file exists locally on device
        final encFile = File('${directory.path}/${item.encryptedFilename}');
        expect(await encFile.exists(), isTrue);

        // Verify reading decrypted data
        final decrypted = utf8.decode(await vault.readDecryptedBytes(item));
        expect(decrypted, payload);

        await vault.close();

        // Reopen vault on Android to verify persistence across restarts
        vault = VaultService(customDir: directory);
        await vault.initialize();

        expect(vault.items, hasLength(1));
        expect(vault.items.single.filename, 'device_test.txt');
        final reopenedDecrypted = utf8.decode(
          await vault.readDecryptedBytes(vault.items.single),
        );
        expect(reopenedDecrypted, payload);

        // Cleanup item
        await vault.deleteItem(item.id);
        expect(vault.items, isEmpty);
        expect(await encFile.exists(), isFalse);

        await vault.close();
      } finally {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      }
    },
  );
}
