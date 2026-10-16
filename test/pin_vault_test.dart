import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:calculator_messenger/core/security/pin_vault.dart';
import 'package:calculator_messenger/core/security/pin_performance.dart';

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

class CountingSecrets extends MemorySecrets {
  int reads = 0, writes = 0;
  bool rejectWrites = false;
  @override
  Future<String?> read(String key) {
    reads++;
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) {
    writes++;
    if (rejectWrites) throw StateError('Storage unavailable');
    return super.write(key, value);
  }
}

void main() {
  test(
    'non-numeric wrong input still persists an unsuccessful attempt',
    () async {
      final store = CountingSecrets();
      final vault = PinVault(store, iterations: 1000);
      await vault.configure('2580');
      expect(await vault.verify('not-a-pin'), isFalse);
      expect(jsonDecode(store.values[PinVault.recordKey]!)['failures'], 1);
    },
  );
  test(
    'clean success reads Keystore but never rewrites a clean record',
    () async {
      final store = CountingSecrets();
      final vault = PinVault(store, iterations: 1000);
      await vault.configure('2580');
      final record = store.values[PinVault.recordKey];
      store.writes = 0;
      store.rejectWrites = true;
      expect(await vault.verify('2580'), isTrue);
      expect(await PinVault(store).verify('2580'), isTrue);
      expect(store.reads, 2);
      expect(store.writes, 0);
      expect(store.values[PinVault.recordKey], record);
    },
  );

  test(
    'dirty success persists reset and fails closed if reset cannot persist',
    () async {
      final store = CountingSecrets();
      final vault = PinVault(store, iterations: 1000);
      await vault.configure('2580');
      expect(await vault.verify('0000'), isFalse);
      expect(jsonDecode(store.values[PinVault.recordKey]!)['failures'], 1);
      store.rejectWrites = true;
      expect(await vault.verify('2580'), isFalse);
      expect(jsonDecode(store.values[PinVault.recordKey]!)['failures'], 1);
      store.rejectWrites = false;
      expect(await vault.verify('2580'), isTrue);
      final reset = jsonDecode(store.values[PinVault.recordKey]!);
      expect(reset['failures'], 0);
      expect(reset['until'], 0);
    },
  );

  test(
    'expired lockout reset persists across a restart, no writes during backoff',
    () async {
      final store = CountingSecrets();
      var now = DateTime.utc(2026);
      final vault = PinVault(store, iterations: 1000, clock: () => now);
      await vault.configure('2580');
      for (var i = 0; i < 5; i++) {
        expect(await vault.verify('0000'), isFalse);
      }
      final writes = store.writes;
      final restarted = PinVault(store, clock: () => now);
      expect(await restarted.verify('2580'), isFalse);
      expect(store.writes, writes);
      now = now.add(const Duration(seconds: 31));
      expect(await restarted.verify('2580'), isTrue);
      expect(store.writes, writes + 1);
      expect(await PinVault(store, clock: () => now).verify('2580'), isTrue);
      expect(store.writes, writes + 1);
    },
  );

  test(
    'v1 independent vectors preserve iteration count and long/leading-zero PINs',
    () async {
      final vectors =
          jsonDecode(
                File('test/fixtures/pin_v1_vectors.json').readAsStringSync(),
              )
              as List;
      for (final vector in vectors) {
        final store = MemorySecrets();
        final record = {...vector as Map, 'failures': 0, 'until': 0}
          ..remove('pin');
        final raw = jsonEncode(record);
        store.values[PinVault.recordKey] = raw;
        final vault = PinVault(
          store,
        ); // Default does not replace stored iterations.
        expect(vault.iterations, 600000);
        expect(await vault.verify(vector['pin'] as String), isTrue);
        expect(store.values[PinVault.recordKey], raw);
      }
    },
  );

  test('optional timing exposes only durations, and reports once', () async {
    final store = MemorySecrets();
    final vault = PinVault(store, iterations: 1000);
    await vault.configure('2580');
    final reports = <Map<String, int>>[];
    final trace = PinTrace(onFinish: reports.add);
    expect(await vault.verify('2580', trace: trace), isTrue);
    trace.finish();
    trace.finish();
    expect(reports, hasLength(1));
    expect(
      reports.single.keys,
      unorderedEquals([
        ...PinStage.values.map((e) => '${e.name}_us'),
        'total_us',
      ]),
    );
    expect(reports.single.values, everyElement(greaterThanOrEqualTo(0)));
    expect(reports.single['storageWrite_us'], 0);
    expect(reports.single['derivation_us'], greaterThan(0));
  });
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
