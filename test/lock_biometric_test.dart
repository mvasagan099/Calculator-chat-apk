import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:calculator_messenger/core/security/lock_controller.dart';
import 'package:calculator_messenger/core/security/pin_vault.dart';
import 'package:calculator_messenger/core/security/pin_performance.dart';
import 'pin_vault_test.dart' show MemorySecrets;
import 'preview_app_test.dart' show PendingVault;

class ImmediatePinVault extends PinVault {
  ImmediatePinVault() : super(MemorySecrets());
  int verifications = 0;
  @override
  Future<bool> verify(String pin, {PinTrace? trace}) async {
    verifications++;
    return pin == '2580';
  }
}

class ControlledBiometrics implements BiometricAuthenticator {
  final started = Completer<void>();
  final requests = <Completer<bool>>[];
  int cancellations = 0;
  @override
  Future<bool> authenticate() {
    final request = Completer<bool>();
    requests.add(request);
    if (!started.isCompleted) started.complete();
    return request.future;
  }

  @override
  Future<void> cancel() async {
    cancellations++;
    // Deliberately allow a late platform success: the epoch must reject it.
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ImmediatePinVault vault;
  late ControlledBiometrics biometrics;
  late LockController lock;
  setUp(() {
    vault = ImmediatePinVault();
    biometrics = ControlledBiometrics();
    lock = LockController(vault, biometrics: biometrics)
      ..hasPin = true
      ..biometricsEnabled = true;
  });
  tearDown(() => lock.dispose());

  test('correct PIN alone never publishes unlocked before biometric success', () async {
    final states = <bool>[];
    lock.addListener(() => states.add(lock.unlocked));
    final result = lock.unlock('2580');
    await biometrics.started.future;
    expect(vault.verifications, 1);
    expect(lock.unlocked, isFalse);
    expect(states, isEmpty);
    biometrics.requests.single.complete(true);
    expect(await result, isTrue);
    expect(states, [true]);
  });

  test('incorrect PIN never requests biometrics', () async {
    expect(await lock.unlock('9999'), isFalse);
    expect(biometrics.requests, isEmpty);
    expect(lock.unlocked, isFalse);
  });

  test('disabled biometrics retain PIN-only unlock', () async {
    lock.biometricsEnabled = false;
    expect(await lock.unlock('2580'), isTrue);
    expect(biometrics.requests, isEmpty);
  });

  test('biometric failure or user cancellation stays locked; retry needs PIN', () async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final result = lock.unlock('2580');
      await Future<void>.delayed(Duration.zero);
      biometrics.requests.last.complete(false);
      expect(await result, isFalse);
      expect(lock.unlocked, isFalse);
      expect(lock.authenticating, isFalse);
    }
    expect(vault.verifications, 2);
  });

  test('platform exception or missing biometric implementation fails closed', () async {
    for (final error in [PlatformException(code: 'userCanceled'), MissingPluginException()]) {
      final result = lock.unlock('2580');
      await Future<void>.delayed(Duration.zero);
      biometrics.requests.last.completeError(error);
      expect(await result, isFalse);
      expect(lock.unlocked, isFalse);
    }
  });

  test('repeated unlocks cannot start concurrent PIN or biometric work', () async {
    final first = lock.unlock('2580');
    await biometrics.started.future;
    expect(await lock.unlock('2580'), isFalse);
    expect(vault.verifications, 1);
    expect(biometrics.requests.length, 1);
    biometrics.requests.single.complete(true);
    expect(await first, isTrue);
  });

  test('system prompt inactive transition is tolerated without opening early', () async {
    final result = lock.unlock('2580');
    await biometrics.started.future;
    lock.didChangeAppLifecycleState(AppLifecycleState.inactive);
    expect(lock.unlocked, isFalse);
    lock.didChangeAppLifecycleState(AppLifecycleState.resumed);
    biometrics.requests.single.complete(true);
    expect(await result, isTrue);
  });

  for (final background in [AppLifecycleState.paused, AppLifecycleState.hidden, AppLifecycleState.detached]) {
    for (final relock in [true, false]) {
      test('$background cancels pending biometrics even with relock=$relock', () async {
        lock.relockOnBackground = relock;
        final result = lock.unlock('2580');
        await biometrics.started.future;
        lock.didChangeAppLifecycleState(background);
        expect(biometrics.cancellations, greaterThan(0));
        expect(await lock.unlock('2580'), isFalse);
        lock.didChangeAppLifecycleState(AppLifecycleState.resumed);
        biometrics.requests.single.complete(true);
        expect(await result, isFalse);
        expect(lock.unlocked, isFalse);
      });
    }
  }

  test('cancelling calculator work rejects late biometric success', () async {
    final result = lock.unlock('2580');
    await biometrics.started.future;
    lock.cancelPendingUnlock();
    biometrics.requests.single.complete(true);
    expect(await result, isFalse);
    expect(biometrics.cancellations, 1);
    expect(lock.unlocked, isFalse);
  });

  test('authorization relock rejects late biometric success', () async {
    final result = lock.unlock('2580');
    await biometrics.started.future;
    lock.lock();
    biometrics.requests.single.complete(true);
    expect(await result, isFalse);
    expect(lock.unlocked, isFalse);
  });

  test('changing biometric policy cannot downgrade an in-flight attempt', () async {
    final result = lock.unlock('2580');
    await biometrics.started.future;
    lock.biometricsEnabled = false;
    biometrics.requests.single.complete(true);
    expect(await result, isFalse);
    expect(lock.unlocked, isFalse);
  });

  test('background during PIN work never starts biometrics on resume', () async {
    final pending = PendingVault();
    final other = LockController(pending, biometrics: biometrics)
      ..hasPin = true
      ..biometricsEnabled = true;
    final result = other.unlock('2580');
    other.didChangeAppLifecycleState(AppLifecycleState.paused);
    other.didChangeAppLifecycleState(AppLifecycleState.resumed);
    pending.verification.complete(true);
    expect(await result, isFalse);
    expect(biometrics.requests, isEmpty);
    other.dispose();
  });

  test('disposal rejects a late successful biometric result', () async {
    final other = LockController(vault, biometrics: biometrics)
      ..hasPin = true
      ..biometricsEnabled = true;
    final result = other.unlock('2580');
    await biometrics.started.future;
    other.dispose();
    biometrics.requests.single.complete(true);
    expect(await result, isFalse);
  });
}
