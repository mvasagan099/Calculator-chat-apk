import 'dart:convert';
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'pin_derivation.dart';
import 'pin_performance.dart';

abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class DeviceSecretStore implements SecretStore {
  const DeviceSecretStore();
  static const _storage = FlutterSecureStorage();
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// The PIN never leaves the device. A verifier and persisted throttle record
/// live together in Android Keystore-backed encrypted storage.
class PinVault {
  PinVault(
    this.store, {
    DateTime Function()? clock,
    this.iterations = 600000,
    this.storageKey = recordKey,
  }) : clock = clock ?? DateTime.now;
  final SecretStore store;
  final DateTime Function() clock;
  final int iterations;
  static const recordKey = 'calculator.pin.v1';
  static const previewKey = 'calculator.preview.pin.v1';
  final String storageKey;
  Future<bool> get configured async => await store.read(storageKey) != null;
  Future<void> configure(String pin) async {
    if (!RegExp(r'^\d{4,8}$').hasMatch(pin)) {
      throw const FormatException('Use 4–8 digits');
    }
    final random = Random.secure();
    final salt = List.generate(32, (_) => random.nextInt(256));
    final hash = await PinDerivation.derive(pin, salt, iterations);
    await store.write(
      storageKey,
      jsonEncode({
        'salt': base64Encode(salt),
        'hash': base64Encode(hash),
        'iterations': iterations,
        'failures': 0,
        'until': 0,
      }),
    );
  }

  bool _busy = false;
  Future<bool> verify(String pin, {PinTrace? trace}) async {
    if (_busy) return false;
    _busy = true;
    final timing = trace ?? PinTrace.begin();
    try {
      final raw = timing == null
          ? await store.read(storageKey)
          : await timing.measure(
              PinStage.storageRead,
              () => store.read(storageKey),
            );
      if (raw == null) return false;
      final r = jsonDecode(raw) as Map<String, dynamic>;
      final now = clock().millisecondsSinceEpoch;
      if (now < (r['until'] as int)) return false;
      final actual = await PinDerivation.derive(
        pin,
        base64Decode(r['salt'] as String),
        r['iterations'] as int,
        trace: timing,
      );
      final expected = base64Decode(r['hash'] as String);
      var difference = actual.length ^ expected.length;
      for (var i = 0; i < actual.length && i < expected.length; i++) {
        difference |= actual[i] ^ expected[i];
      }
      if (difference == 0) {
        // Keystore reads stay authoritative. Skip only an already-clean reset;
        // failed attempts and a successful dirty reset must still persist.
        if (r['failures'] == 0 && r['until'] == 0) return true;
        r['failures'] = 0;
        r['until'] = 0;
      } else {
        final failures = (r['failures'] as int) + 1;
        r['failures'] = failures;
        r['until'] =
            now +
            (failures < 5
                ? 0
                : min(3600, 30 * pow(2, min(7, failures - 5))).toInt() * 1000);
      }
      if (timing == null) {
        await store.write(storageKey, jsonEncode(r));
      } else {
        await timing.measure(
          PinStage.storageWrite,
          () => store.write(storageKey, jsonEncode(r)),
        );
      }
      return difference == 0;
    } catch (_) {
      return false;
    } finally {
      _busy = false;
      if (trace == null) timing?.finish();
    }
  }

  Future<void> clear() => store.delete(storageKey);
}
