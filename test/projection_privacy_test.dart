import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:calculator_messenger/core/security/lock_controller.dart';
import 'package:calculator_messenger/core/security/pin_vault.dart';
import 'pin_vault_test.dart' show MemorySecrets;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('locked calculator never requests projection consent', () async {
    final lock = LockController(PinVault(MemorySecrets(), iterations: 1000));
    var requested = false;
    expect(
      await lock.projectionConsent(() async {
        requested = true;
        return true;
      }),
      isFalse,
    );
    expect(requested, isFalse);
    lock.dispose();
  });
  test(
    'explicit projection system prompt tolerates inactive but not background',
    () async {
      final lock = LockController(PinVault(MemorySecrets(), iterations: 1000))
        ..hasPin = true
        ..unlocked = true;
      final consent = Completer<bool>();
      final result = lock.projectionConsent(() => consent.future);
      lock.didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(lock.unlocked, isTrue);
      lock.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(lock.unlocked, isFalse);
      consent.complete(true);
      expect(await result, isFalse);
      lock.dispose();
    },
  );
  test('manual relock invalidates pending screen-capture permission', () async {
    final lock = LockController(PinVault(MemorySecrets(), iterations: 1000))
      ..hasPin = true
      ..unlocked = true;
    final consent = Completer<bool>();
    final result = lock.projectionConsent(() => consent.future);
    lock.lock();
    consent.complete(true);
    expect(await result, isFalse);
    lock.dispose();
  });
}
