import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:calculator_messenger/core/security/lock_controller.dart';
import 'package:calculator_messenger/core/widgets/private_scaffold.dart';
import 'package:calculator_messenger/providers/app_providers.dart';
import 'lock_biometric_test.dart' show ImmediatePinVault;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ImmediatePinVault vault;
  late LockController lock;
  final channelCalls = <MethodCall>[];

  setUp(() {
    channelCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('calculator_messenger/privacy'),
      (call) async {
        channelCalls.add(call);
        return null;
      },
    );

    vault = ImmediatePinVault();
    lock = LockController(vault)..hasPin = true;
  });

  tearDown(() {
    lock.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('calculator_messenger/privacy'),
      null,
    );
  });

  group('LockController Quick Lock & Shake-to-Lock', () {
    test('quickLock immediately sets unlocked to false and triggers onRelock', () {
      lock.unlocked = true;
      var relockTriggered = false;
      lock.onRelock = () {
        relockTriggered = true;
      };

      expect(lock.unlocked, isTrue);
      lock.quickLock();

      expect(lock.unlocked, isFalse);
      expect(relockTriggered, isTrue);
    });

    test('quickLock when already locked is a safe no-op without re-firing onRelock', () {
      lock.unlocked = false;
      var relockTriggered = false;
      lock.onRelock = () {
        relockTriggered = true;
      };

      lock.quickLock();

      expect(lock.unlocked, isFalse);
      expect(relockTriggered, isFalse);
    });

    test('onRelock errors do not crash or prevent lock completion', () {
      lock.unlocked = true;
      lock.onRelock = () {
        throw StateError('Simulated listener error');
      };

      expect(() => lock.quickLock(), returnsNormally);
      expect(lock.unlocked, isFalse);
    });

    test('setShakeToLock dispatches method call to native privacy channel', () async {
      await lock.setShakeToLock(true);
      expect(channelCalls.any((c) => c.method == 'setShakeToLock' && c.arguments == true), Platform.isAndroid);

      await lock.setShakeToLock(false);
      expect(channelCalls.any((c) => c.method == 'setShakeToLock' && c.arguments == false), Platform.isAndroid);
    });

    test('native quickLock method call from platform channel locks the controller', () async {
      lock.unlocked = true;
      var relockFired = false;
      lock.onRelock = () => relockFired = true;

      // Simulate native shake sensor invoking method on privacyChannel
      final encoded = const StandardMethodCodec().encodeMethodCall(
        const MethodCall('quickLock'),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage('calculator_messenger/privacy', encoded, (ByteData? _) {});

      expect(lock.unlocked, isFalse);
      expect(relockFired, isTrue);
    });
  });

  group('PrivateScaffold Quick Lock UI and Shortcuts', () {
    testWidgets('quick lock app bar button invokes lock.quickLock', (tester) async {
      lock.unlocked = true;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [lockProvider.overrideWithValue(lock)],
          child: const MaterialApp(
            home: PrivateScaffold(
              title: 'Messages',
              index: 0,
              body: Center(child: Text('Confidential Chat')),
            ),
          ),
        ),
      );

      expect(find.text('Confidential Chat'), findsOneWidget);
      final quickLockBtn = find.byTooltip('Quick Lock (Return to Calculator)');
      expect(quickLockBtn, findsOneWidget);

      await tester.tap(quickLockBtn);
      await tester.pump();

      expect(lock.unlocked, isFalse);
    });

    testWidgets('pressing Escape key triggers quickLock', (tester) async {
      lock.unlocked = true;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [lockProvider.overrideWithValue(lock)],
          child: const MaterialApp(
            home: PrivateScaffold(
              title: 'Messages',
              index: 0,
              body: Center(child: Text('Confidential Content')),
            ),
          ),
        ),
      );

      // Simulate pressing the Escape key
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(lock.unlocked, isFalse);
    });

    testWidgets('pressing Ctrl+Alt+L shortcut triggers quickLock', (tester) async {
      lock.unlocked = true;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [lockProvider.overrideWithValue(lock)],
          child: const MaterialApp(
            home: PrivateScaffold(
              title: 'Messages',
              index: 0,
              body: Center(child: Text('Confidential Content')),
            ),
          ),
        ),
      );

      // Simulate Ctrl+Alt+L key combination
      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.alt);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.alt);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pump();

      expect(lock.unlocked, isFalse);
    });
  });
}
