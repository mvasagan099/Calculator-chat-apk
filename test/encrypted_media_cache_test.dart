import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:calculator_messenger/core/security/encrypted_media_cache.dart';
import 'package:calculator_messenger/core/security/pin_vault.dart';

class MemoryKeyStore implements SecretStore {
  final records = <String, String>{};
  @override
  Future<String?> read(String key) async => records[key];
  @override
  Future<void> write(String key, String value) async { records[key] = value; }
  @override
  Future<void> delete(String key) async { records.remove(key); }
}

Map<String, dynamic> attachment(DateTime? deadline, {
  String objectPath = 'chat/owner/photo.jpg',
  String mime = 'image/jpeg',
  int size = 5,
}) => {
  'object_path': objectPath,
  'mime_type': mime,
  'size_bytes': size,
  if (deadline != null) 'media_expires_at': deadline.toIso8601String(),
};

void main() {
  test('encrypted media survives restart without plaintext and is scoped by owner', () async {
    final directory = await Directory.systemTemp.createTemp('encrypted-media-test');
    try {
      final store = MemoryKeyStore();
      final metadata = attachment(DateTime.now().add(const Duration(hours: 2)));
      final bytes = Uint8List.fromList([40, 41, 42, 43, 44]);
      final first = EncryptedMediaCache(directory: directory, secretStore: store);
      await first.write(owner: 'alice', attachment: metadata, bytes: bytes);
      final files = await directory.list(recursive: true).where((x) => x is File).toList();
      expect(files.length, 1);
      final disk = await (files.single as File).readAsBytes();
      expect(disk.length, 36 + bytes.length);
      expect(disk.sublist(36), isNot(bytes));
      final afterRestart = EncryptedMediaCache(directory: directory, secretStore: store);
      expect(await afterRestart.read(owner: 'alice', attachment: metadata), bytes);
      expect(await afterRestart.read(owner: 'bob', attachment: metadata), isNull);
    } finally { await directory.delete(recursive: true); }
  });

  test('expired and shortened policies invalidate sealed media', () async {
    final directory = await Directory.systemTemp.createTemp('encrypted-media-expiry');
    try {
      final store = MemoryKeyStore();
      var now = DateTime.utc(2026, 10, 19);
      final cache = EncryptedMediaCache(directory: directory, secretStore: store, clock: () => now);
      final original = attachment(now.add(const Duration(hours: 2)));
      await cache.write(owner: 'alice', attachment: original, bytes: Uint8List(5));
      expect(await cache.read(owner: 'alice', attachment: original), isNotNull);
      final changed = attachment(now.add(const Duration(minutes: 3)));
      expect(await cache.read(owner: 'alice', attachment: changed), isNull);
      await cache.write(owner: 'alice', attachment: changed, bytes: Uint8List(5));
      now = now.add(const Duration(minutes: 4));
      expect(await cache.read(owner: 'alice', attachment: changed), isNull);
      expect(await cache.diskBytes('alice'), 0);
    } finally { await directory.delete(recursive: true); }
  });

  test('tampering and view-once data fail closed', () async {
    final directory = await Directory.systemTemp.createTemp('encrypted-media-corrupt');
    try {
      final store = MemoryKeyStore();
      final cache = EncryptedMediaCache(directory: directory, secretStore: store);
      final metadata = attachment(DateTime.now().add(const Duration(days: 1)));
      await cache.write(owner: 'alice', attachment: metadata, bytes: Uint8List.fromList([1,2,3,4,5]));
      final file = (await directory.list(recursive: true).where((x) => x is File).first) as File;
      final raw = await file.readAsBytes();
      raw[37] ^= 1;
      await file.writeAsBytes(raw);
      expect(await cache.read(owner: 'alice', attachment: metadata), isNull);
      expect(await file.exists(), isFalse);
      final once = {...metadata, 'view_once': true};
      await cache.write(owner: 'alice', attachment: once, bytes: Uint8List(5));
      expect(await cache.diskBytes('alice'), 0);
      expect(await cache.read(owner: 'alice', attachment: once), isNull);
    } finally { await directory.delete(recursive: true); }
  });

  test('LRU eviction enforces budget without touching unrelated files', () async {
    final root = await Directory.systemTemp.createTemp('encrypted-media-budget');
    try {
      final unrelated = await File('${root.path}/private-vault').writeAsString('KEEP');
      final cache = EncryptedMediaCache(
        directory: Directory('${root.path}/cache'),
        secretStore: MemoryKeyStore(),
        maxCacheBytes: 80,
      );
      final deadline = DateTime.now().add(const Duration(hours: 2));
      final first = attachment(deadline, objectPath: 'chat/one');
      final second = attachment(deadline, objectPath: 'chat/two');
      await cache.write(owner: 'alice', attachment: first, bytes: Uint8List(5));
      await cache.write(owner: 'alice', attachment: second, bytes: Uint8List(5));
      expect(await cache.diskBytes('alice'), lessThanOrEqualTo(80));
      expect(await cache.read(owner: 'alice', attachment: first), isNull);
      expect(await cache.read(owner: 'alice', attachment: second), isNotNull);
      await cache.clear('alice');
      expect(await unrelated.readAsString(), 'KEEP');
    } finally { await root.delete(recursive: true); }
  });

  test('audio is eligible; missing visual deadline and view-once are excluded', () {
    expect(EncryptedMediaCache.eligible(attachment(null)), isFalse);
    expect(EncryptedMediaCache.eligible(attachment(null, mime: 'audio/mp4')), isTrue);
    expect(EncryptedMediaCache.eligible({...attachment(DateTime.now()), 'is_view_once': true}), isFalse);
  });
}
