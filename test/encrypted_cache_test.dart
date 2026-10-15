import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:calculator_messenger/core/security/encrypted_cache.dart';
import 'pin_vault_test.dart' show MemorySecrets;

void main() {
  test(
    'cache persists authenticated ciphertext and fails closed on tampering',
    () async {
      final dir = await Directory.systemTemp.createTemp('messenger-cache-test');
      try {
        final secrets = MemorySecrets();
        final cache = EncryptedCache('alice', secrets, directory: dir);
        await cache.initialize();
        cache.data['message'] = 'private words';
        await cache.save();
        final file = File('${dir.path}/cache-alice.bin');
        expect(await file.readAsString(), isNot(contains('private words')));
        final restored = EncryptedCache('alice', secrets, directory: dir);
        await restored.initialize();
        expect(restored.data['message'], 'private words');
        final bob = EncryptedCache('bob', secrets, directory: dir);
        await bob.initialize();
        await File(
          '${dir.path}/cache-bob.bin',
        ).writeAsString(await file.readAsString());
        await bob.initialize();
        expect(bob.data, isEmpty);
        await file.writeAsString('{"data":"tampered"}');
        await restored.initialize();
        expect(restored.data, isEmpty);
        await restored.clear();
        expect(await file.exists(), isFalse);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
  test('queued writes retain the most recent outbox', () async {
    final dir = await Directory.systemTemp.createTemp('messenger-cache-test');
    try {
      final secrets = MemorySecrets();
      final cache = EncryptedCache('alice', secrets, directory: dir);
      await cache.initialize();
      cache.data['outbox'] = [1];
      final first = cache.save();
      cache.data['outbox'] = [1, 2];
      final second = cache.save();
      await Future.wait([first, second]);
      final restored = EncryptedCache('alice', secrets, directory: dir);
      await restored.initialize();
      expect(restored.data['outbox'], [1, 2]);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
