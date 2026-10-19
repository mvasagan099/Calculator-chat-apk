import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';

import 'pin_vault.dart';

/// Account-scoped, encrypted, bounded and regenerable local chat-media cache.
/// It does not touch SQLite drafts, private vault data, or Supabase tables.
class EncryptedMediaCache {
  EncryptedMediaCache({
    this.directory,
    SecretStore? secretStore,
    DateTime Function()? clock,
    this.maxCacheBytes = 100 * 1024 * 1024,
    this.maxAge = const Duration(days: 3),
  }) : store = secretStore ?? const DeviceSecretStore(),
       clock = clock ?? DateTime.now;

  final Directory? directory;
  final SecretStore store;
  final DateTime Function() clock;
  final int maxCacheBytes;
  final Duration maxAge;
  final AesGcm cipher = AesGcm.with256bits();

  Future<String> _hash(String value) async {
    final bytes = (await Sha256().hash(utf8.encode(value))).bytes;
    return bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<Directory> _root() async => directory ??
      Directory('${(await getApplicationSupportDirectory()).path}/encrypted-chat-media-v1');

  Future<Directory> _ownerFolder(String owner) async =>
      Directory('${(await _root()).path}/${await _hash(owner)}');

  Future<File> _file(String owner, String path, String mime, int size) async =>
      File('${(await _ownerFolder(owner)).path}/${await _hash('$owner|$path|$mime|$size')}.bin');

  Future<SecretKey?> _key(String owner, {required bool create}) async {
    final identifier = 'chat.media.cache.key.v1.${await _hash(owner)}';
    var encoded = await store.read(identifier);
    if (encoded == null && create) {
      final random = await cipher.newSecretKey();
      encoded = base64Encode(await random.extractBytes());
      await store.write(identifier, encoded);
    }
    if (encoded == null) return null;
    final bytes = base64Decode(encoded);
    if (bytes.length != 32) throw StateError('Invalid encrypted media key');
    return SecretKey(bytes);
  }

  String _aad(String owner, String path, String mime, int size, int expiry) =>
      'chat-media-v1|$owner|$path|$mime|$size|$expiry';

  static bool eligible(Map<String, dynamic> attachment) {
    final size = attachment['size_bytes'];
    final path = attachment['object_path'];
    final mime = attachment['mime_type'];
    if (attachment['view_once'] == true ||
        attachment['is_view_once'] == true ||
        attachment['deleted_at'] != null ||
        size is! int || size < 1 || size > 25 * 1024 * 1024 ||
        path is! String || path.isEmpty || mime is! String || mime.isEmpty) {
      return false;
    }
    for (final field in ['expires_at', 'media_expires_at']) {
      final raw = attachment[field];
      if (raw != null && DateTime.tryParse(raw.toString()) == null) return false;
    }
    if ((mime.startsWith('image/') || mime.startsWith('video/')) &&
        attachment['media_expires_at'] == null) {
      return false;
    }
    return true;
  }

  DateTime expiration(Map<String, dynamic> attachment) {
    var expires = clock().add(maxAge);
    for (final field in ['expires_at', 'media_expires_at']) {
      final raw = attachment[field];
      if (raw == null) continue;
      final value = DateTime.parse(raw.toString());
      if (value.isBefore(expires)) expires = value;
    }
    return expires;
  }

  /// Callers must check account/device/PIN authorization before AND after await.
  Future<Uint8List?> read({
    required String owner,
    required Map<String, dynamic> attachment,
  }) async {
    if (owner.isEmpty || !eligible(attachment)) return null;
    final current = clock();
    if (!expiration(attachment).isAfter(current)) return null;
    final path = attachment['object_path'] as String;
    final mime = attachment['mime_type'] as String;
    final size = attachment['size_bytes'] as int;
    final file = await _file(owner, path, mime, size);
    if (!await file.exists()) return null;
    try {
      final raw = await file.readAsBytes();
      if (raw.length != 36 + size) throw const FormatException('Invalid media cache entry');
      final expiry = ByteData.sublistView(raw, 0, 8).getInt64(0, Endian.big);
      final deadline = DateTime.fromMillisecondsSinceEpoch(expiry);
      if (!deadline.isAfter(current) ||
          deadline.isAfter(expiration(attachment))) {
        await file.delete();
        return null;
      }
      final key = await _key(owner, create: false);
      if (key == null) {
        await file.delete();
        return null;
      }
      final box = SecretBox(
        raw.sublist(36),
        nonce: raw.sublist(8, 20),
        mac: Mac(raw.sublist(20, 36)),
      );
      final plain = Uint8List.fromList(await cipher.decrypt(
        box,
        secretKey: key,
        aad: utf8.encode(_aad(owner, path, mime, size, expiry)),
      ));
      if (plain.length != size) throw const FormatException('Cache size mismatch');
      await file.setLastModified(current);
      return plain;
    } catch (_) {
      try { if (await file.exists()) await file.delete(); } catch (_) {}
      return null;
    }
  }

  Future<void> write({
    required String owner,
    required Map<String, dynamic> attachment,
    required Uint8List bytes,
  }) async {
    if (owner.isEmpty || !eligible(attachment) ||
        bytes.length != attachment['size_bytes']) {
      return;
    }
    final deadline = expiration(attachment);
    if (!deadline.isAfter(clock())) return;
    final path = attachment['object_path'] as String;
    final mime = attachment['mime_type'] as String;
    final size = attachment['size_bytes'] as int;
    final expiry = deadline.millisecondsSinceEpoch;
    final key = await _key(owner, create: true);
    if (key == null) return;
    final box = await cipher.encrypt(
      bytes,
      secretKey: key,
      aad: utf8.encode(_aad(owner, path, mime, size, expiry)),
    );
    final header = ByteData(8)..setInt64(0, expiry, Endian.big);
    final sealed = Uint8List.fromList([
      ...header.buffer.asUint8List(),
      ...box.nonce,
      ...box.mac.bytes,
      ...box.cipherText,
    ]);
    final folder = await _ownerFolder(owner);
    await folder.create(recursive: true);
    final file = await _file(owner, path, mime, size);
    final temp = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    try {
      await temp.writeAsBytes(sealed, flush: true);
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
    await prune(owner);
  }

  /// Deletes expired entries and evicts oldest entries first. Never touches vault.
  Future<void> prune(String owner) async {
    final folder = await _ownerFolder(owner);
    if (!await folder.exists()) return;
    final entries = <(File, int, DateTime)>[];
    var total = 0;
    await for (final entry in folder.list(followLinks: false)) {
      if (entry is! File) continue;
      try {
        final size = await entry.length();
        // Concurrent downloads may be writing encrypted .tmp payloads.
        // Never delete live writers' files during eviction.
        if (entry.path.endsWith('.tmp')) {
          if ((await entry.lastModified()).isBefore(
              clock().subtract(const Duration(hours: 1)))) {
            await entry.delete();
          }
          continue;
        }
        if (!entry.path.endsWith('.bin') || size < 36 ||
            size > 25 * 1024 * 1024 + 36) {
          await entry.delete();
          continue;
        }
        final reader = await entry.open(mode: FileMode.read);
        late final List<int> header;
        try { header = await reader.read(8); } finally { await reader.close(); }
        if (header.length != 8 ||
            !DateTime.fromMillisecondsSinceEpoch(
              ByteData.sublistView(Uint8List.fromList(header))
                  .getInt64(0, Endian.big),
            ).isAfter(clock())) {
          await entry.delete();
          continue;
        }
        entries.add((entry, size, await entry.lastModified()));
        total += size;
      } catch (_) {
        try { if (await entry.exists()) await entry.delete(); } catch (_) {}
      }
    }
    entries.sort((a, b) => a.$3.compareTo(b.$3));
    for (final (file, size, _) in entries) {
      if (total <= maxCacheBytes) break;
      try { await file.delete(); total -= size; } catch (_) {}
    }
  }

  Future<void> clear(String owner) async {
    final folder = await _ownerFolder(owner);
    if (await folder.exists()) await folder.delete(recursive: true);
  }

  Future<int> diskBytes(String owner) async {
    final folder = await _ownerFolder(owner);
    if (!await folder.exists()) return 0;
    var bytes = 0;
    await for (final entry in folder.list(followLinks: false)) {
      if (entry is File) bytes += await entry.length();
    }
    return bytes;
  }
}
