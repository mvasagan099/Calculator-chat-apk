import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';
import 'pin_vault.dart';
import 'local_retention.dart';
import 'local_cache.dart';

class EncryptedCache implements LocalCache {
  EncryptedCache(
    this.userId,
    this.store, {
    this.directory,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;
  final DateTime Function() clock;
  final String userId;
  final SecretStore store;
  final Directory? directory;
  final _cipher = AesGcm.with256bits();
  SecretKey? _key;
  File? _file;
  @override
  Map<String, dynamic> data = {};
  Future<void> _writes = Future.value();
  @override
  Future<void> initialize() async {
    final keyName = 'cache.key.$userId';
    var raw = await store.read(keyName);
    if (raw == null) {
      raw = base64Encode(await (await _cipher.newSecretKey()).extractBytes());
      await store.write(keyName, raw);
    }
    _key = SecretKey(base64Decode(raw));
    _file = File(
      '${(directory ?? await getApplicationSupportDirectory()).path}/cache-$userId.bin',
    );
    if (await _file!.exists()) {
      try {
        final envelope = jsonDecode(await _file!.readAsString());
        final box = SecretBox(
          base64Decode(envelope['data']),
          nonce: base64Decode(envelope['nonce']),
          mac: Mac(base64Decode(envelope['mac'])),
        );
        data =
            jsonDecode(
                  utf8.decode(
                    await _cipher.decrypt(
                      box,
                      secretKey: _key!,
                      aad: utf8.encode(userId),
                    ),
                  ),
                )
                as Map<String, dynamic>;
      } catch (_) {
        data = {}; /* Corrupt caches never replace the server. */
      }
    }
    pruneLocalData(data, clock());
    if (data.isNotEmpty) await save();
  }

  @override
  Future<void> save() {
    pruneLocalData(data, clock());
    final snapshot = jsonEncode(data);
    _writes = _writes.catchError((Object _) {}).then((_) async {
      final box = await _cipher.encrypt(
        utf8.encode(snapshot),
        secretKey: _key!,
        aad: utf8.encode(userId),
      );
      final temp = File('${_file!.path}.tmp');
      await temp.writeAsString(
        jsonEncode({
          'data': base64Encode(box.cipherText),
          'nonce': base64Encode(box.nonce),
          'mac': base64Encode(box.mac.bytes),
        }),
        flush: true,
      );
      await temp.rename(_file!.path);
    });
    return _writes;
  }

  /// Release references after outstanding writes; encrypted history and the
  /// Keystore-wrapped key remain for the next authenticated unlock.
  @override
  Future<void> forget() async {
    await _writes.catchError((Object _) {});
    data = {};
    _key = null;
    _file = null;
  }

  @override
  Future<void> clear() async {
    await _writes.catchError((Object _) {});
    data = {};
    _file ??= File(
      '${(directory ?? await getApplicationSupportDirectory()).path}/cache-$userId.bin',
    );
    if (await _file!.exists()) await _file!.delete();
    await store.delete('cache.key.$userId');
  }
}
