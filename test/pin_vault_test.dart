import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:calculator_messenger/core/security/pin_vault.dart';

class MemorySecrets implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  test(
    'salted verifier, no plaintext PIN, constant verification result',
    () async {
      final storage = MemorySecrets();
      final vault = PinVault(storage, iterations: 1000);
      await vault.configure('258012');
      final first = jsonDecode(storage.values[PinVault.recordKey]!);
      expect(storage.values[PinVault.recordKey], isNot(contains('258012')));
      expect(await vault.verify('258012'), isTrue);
      expect(await vault.verify('258013'), isFalse);
      await vault.configure('258012');
      expect(
        jsonDecode(storage.values[PinVault.recordKey]!)['salt'],
        isNot(first['salt']),
      );
    },
  );
  test('throttle survives constructing a new vault', () async {
    final storage = MemorySecrets();
    var now = DateTime.utc(2026);
    var vault = PinVault(storage, iterations: 1000, clock: () => now);
    await vault.configure('258012');
    for (var i = 0; i < 5; i++) {
      expect(await vault.verify('000000'), isFalse);
    }
    vault = PinVault(storage, iterations: 1000, clock: () => now);
    expect(await vault.verify('258012'), isFalse);
    now = now.add(const Duration(seconds: 31));
    expect(await vault.verify('258012'), isTrue);
  });
  test('invalid, missing and corrupt storage fail closed', () async {
    final storage = MemorySecrets();
    final vault = PinVault(storage, iterations: 1000);
    expect(await vault.verify('258012'), isFalse);
    await expectLater(vault.configure('123'), throwsFormatException);
    storage.values[PinVault.recordKey] = 'corrupt';
    expect(await vault.verify('258012'), isFalse);
  });
  test(
    'new PINs support four to eight digits including leading zeroes',
    () async {
      final vault = PinVault(MemorySecrets(), iterations: 1000);
      for (final pin in ['2580', '0000', '01234567']) {
        await vault.configure(pin);
        expect(await vault.verify(pin), isTrue);
      }
      for (final pin in ['123', '123456789', '12a4', '12 4', '']) {
        await expectLater(vault.configure(pin), throwsFormatException);
      }
    },
  );
  test('preview PIN cannot replace or clear the account PIN', () async {
    final store = MemorySecrets();
    final account = PinVault(store, iterations: 1000);
    final preview = PinVault(
      store,
      iterations: 1000,
      storageKey: PinVault.previewKey,
    );
    await account.configure('641862');
    await preview.configure('2580');
    expect(await account.verify('2580'), isFalse);
    expect(await preview.verify('641862'), isFalse);
    await preview.clear();
    expect(await account.verify('641862'), isTrue);
    expect(await preview.configured, isFalse);
  });
}
