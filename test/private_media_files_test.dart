import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:calculator_messenger/core/security/private_media_files.dart';
import 'package:calculator_messenger/core/security/encrypted_cache.dart';
import 'pin_vault_test.dart' show MemorySecrets;

void main() {
  test(
    'private viewer files use unique names and startup cleanup is scoped',
    () async {
      final root = await Directory.systemTemp.createTemp('private-media-test');
      try {
        final outside = await File(
          '${root.path}/keep',
        ).writeAsString('unrelated');
        final files = PrivateMediaFiles(root: Directory('${root.path}/owned'));
        final first = await files.video(Uint8List.fromList([1, 2, 3]));
        final second = await files.video(Uint8List.fromList([4, 5]));
        expect(first.path, isNot(second.path));
        await first.delete();
        await files.clear();
        expect(await second.exists(), isFalse);
        expect(await outside.readAsString(), 'unrelated');
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'expired content is removed from encrypted disk after an offline restart',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'expiration-cache-test',
      );
      try {
        var now = DateTime.utc(2026, 10, 15);
        final store = MemorySecrets();
        final first = EncryptedCache(
          'owner',
          store,
          directory: root,
          clock: () => now,
        );
        await first.initialize();
        first.data['messages.chat'] = [
          {
            'id': 'message',
            'body': 'private text',
            'expires_at': now.add(const Duration(hours: 24)).toIso8601String(),
          },
        ];
        await first.save();
        now = now.add(const Duration(days: 2));
        final second = EncryptedCache(
          'owner',
          store,
          directory: root,
          clock: () => now,
        );
        await second.initialize();
        expect(second.data['messages.chat'], isEmpty);
        final third = EncryptedCache(
          'owner',
          store,
          directory: root,
          clock: () => DateTime.utc(2026),
        );
        await third.initialize();
        expect(third.data['messages.chat'], isEmpty);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
