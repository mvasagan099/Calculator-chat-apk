import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:calculator_messenger/core/security/lock_controller.dart';
import 'package:calculator_messenger/core/security/media_picker_platform.dart';
import 'lock_biometric_test.dart' show ImmediatePinVault;

class ControlledMediaPicker implements MediaPickerPlatform {
  @override
  void Function(String)? onInvalidated;
  String? token, kind;
  bool trusted = true;
  int launches = 0, finishes = 0;
  @override
  Future<bool> arm(String token, String kind) async {
    this.token = token; this.kind = kind; launches++;
    return trusted;
  }
  @override
  Future<bool> finish(String token) async { finishes++; return trusted && this.token == token; }
  @override
  Future<void> cancel(String token) async { if (this.token == token) this.token = null; }
  void leave() {
    final id = token;
    if (id != null) onInvalidated?.call(id);
  }
}

void main() {
  for (final kind in ['image', 'video', 'camera', 'document']) {
    testWidgets('$kind return needs native proof and authorization', (tester) async {
      final platform = ControlledMediaPicker();
      final lock = LockController(ImmediatePinVault(), mediaPicker: platform)..hasPin = true;
      await lock.unlock('2580');
      var rechecked = false;
      final selected = Completer<String?>();
      final result = lock.pickMedia(kind, () => selected.future,
        authorized: () => true, reauthorize: () async { rechecked = true; return true; });
      await tester.pump();
      expect(platform.kind, kind);
      for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        lock.didChangeAppLifecycleState(state);
      }
      expect(lock.unlocked, isTrue);
      expect(lock.mediaPickerActive, isTrue);
      expect(rechecked, isFalse);
      lock.didChangeAppLifecycleState(AppLifecycleState.resumed);
      selected.complete('selected-file');
      await tester.pump();
      expect(await result, 'selected-file');
      expect(rechecked, isTrue);
      expect(lock.mediaPickerActive, isFalse);
      expect(lock.unlocked, isTrue);
      lock.dispose();
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
  for (final reason in ['Home', 'Recents', 'screen off', 'manual lock', 'session revocation', 'device authorization', 'account change', 'timeout', 'process detach']) {
    testWidgets('$reason rejects stale selection without reopening', (tester) async {
      final platform = ControlledMediaPicker();
      final lock = LockController(ImmediatePinVault(), mediaPicker: platform)..hasPin = true;
      await lock.unlock('2580');
      var authorized = true;
      final selected = Completer<String?>();
      final result = lock.pickMedia('image', () => selected.future,
        authorized: () => authorized, reauthorize: () async => authorized);
      await tester.pump();
      if (['Home', 'Recents', 'screen off'].contains(reason)) {
        platform.leave();
      } else if (['session revocation', 'device authorization', 'account change'].contains(reason)) {
        authorized = false;
        lock.lock(); // Existing AuthService invalidation path.
      } else if (reason == 'timeout') {
        await tester.pump(const Duration(minutes: 2));
      } else if (reason == 'process detach') {
        lock.didChangeAppLifecycleState(AppLifecycleState.detached);
      } else { lock.lock(); }
      selected.complete('stale-file');
      await tester.pump();
      expect(await result, isNull);
      expect(lock.unlocked, isFalse);
      expect(lock.mediaPickerActive, isFalse);
      lock.dispose();
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
  testWidgets('normal background still locks without a picker', (tester) async {
    final lock = LockController(ImmediatePinVault(), mediaPicker: ControlledMediaPicker())..hasPin = true;
    await lock.unlock('2580');
    lock.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(lock.unlocked, isFalse);
    lock.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
  testWidgets('cancelled selection returns no media and stays unlocked', (tester) async {
    final lock = LockController(ImmediatePinVault(), mediaPicker: ControlledMediaPicker())..hasPin = true;
    await lock.unlock('2580');
    final result = lock.pickMedia<String>('image', () async => null,
      authorized: () => true, reauthorize: () async => true);
    await tester.pump();
    expect(await result, isNull);
    expect(lock.unlocked, isTrue);
    lock.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
  testWidgets('failed native proof or authorization keeps private UI locked', (tester) async {
    for (final native in [false, true]) {
      final platform = ControlledMediaPicker();
      final lock = LockController(ImmediatePinVault(), mediaPicker: platform)..hasPin = true;
      await lock.unlock('2580');
      final selected = Completer<String?>();
      final result = lock.pickMedia('image', () => selected.future,
        authorized: () => true, reauthorize: () async => false);
      await tester.pump();
      platform.trusted = native;
      selected.complete('file');
      await tester.pump();
      expect(await result, isNull);
      expect(lock.unlocked, isFalse);
      lock.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
  testWidgets('repeated launch and PIN entry are rejected during picker work', (tester) async {
    final platform = ControlledMediaPicker();
    final lock = LockController(ImmediatePinVault(), mediaPicker: platform)..hasPin = true;
    await lock.unlock('2580');
    final selected = Completer<String?>();
    final result = lock.pickMedia('image', () => selected.future,
      authorized: () => true, reauthorize: () async => true);
    await tester.pump();
    await expectLater(lock.pickMedia('video', () async => 'other',
      authorized: () => true, reauthorize: () async => true), throwsStateError);
    expect(await lock.unlock('2580'), isFalse);
    expect(platform.launches, 1);
    selected.complete(null);
    await tester.pump();
    await result;
    lock.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
  testWidgets('old result cannot post or relock a newly unlocked session', (tester) async {
    final lock = LockController(ImmediatePinVault(), mediaPicker: ControlledMediaPicker())..hasPin = true;
    await lock.unlock('2580');
    final selected = Completer<String?>();
    final result = lock.pickMedia('image', () => selected.future,
      authorized: () => true, reauthorize: () async => true);
    await tester.pump();
    lock.lock();
    await lock.unlock('2580');
    selected.complete('old');
    await tester.pump();
    expect(await result, isNull);
    expect(lock.unlocked, isTrue);
    lock.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
  testWidgets('Home during return authorization check immediately locks', (tester) async {
    final platform = ControlledMediaPicker();
    final lock = LockController(ImmediatePinVault(), mediaPicker: platform)..hasPin = true;
    await lock.unlock('2580');
    final approval = Completer<bool>();
    final result = lock.pickMedia('image', () async => 'file',
      authorized: () => true, reauthorize: () => approval.future);
    await tester.pump();
    expect(platform.finishes, 1);
    lock.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(lock.unlocked, isFalse);
    lock.didChangeAppLifecycleState(AppLifecycleState.resumed);
    approval.complete(true);
    await tester.pump();
    expect(await result, isNull);
    expect(lock.unlocked, isFalse);
    lock.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
