// Run only on an owner-approved disposable Android device/profile. This uses
// a unique test namespace and never reads/resets an existing account or PIN.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:uuid/uuid.dart';
import 'package:calculator_messenger/core/security/pin_vault.dart';
import 'package:calculator_messenger/core/security/sqlite_cache.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android SQLite and secure-store round trip in an isolated namespace',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'sqlite-device-probe-',
      );
      final owner = 'storage_probe_${const Uuid().v4()}';
      const secrets = DeviceSecretStore();
      var cache = SqliteEncryptedCache(owner, secrets, directory: directory);
      try {
        await cache.initialize();
        cache.data['outbox'] = [
          {'id': 'device-probe', 'body': 'Nonpersonal integration fixture'},
        ];
        await cache.save();
        await cache.forget();
        cache = SqliteEncryptedCache(owner, secrets, directory: directory);
        await cache.initialize();
        expect(cache.data['outbox'][0]['id'], 'device-probe');
        expect(await secrets.read('cache.key.$owner'), isNotNull);
      } finally {
        await cache.clear();
        await directory.delete(recursive: true);
      }
      expect(await secrets.read('cache.key.$owner'), isNull);
    },
  );
}
