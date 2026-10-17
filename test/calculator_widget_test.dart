import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:calculator_messenger/core/security/lock_controller.dart';
import 'package:calculator_messenger/core/security/pin_vault.dart';
import 'package:calculator_messenger/features/calculator/calculator_screen.dart';
import 'preview_app_test.dart' show PendingVault;
import 'pin_vault_test.dart' show MemorySecrets;
import 'lock_biometric_test.dart' show ControlledBiometrics, ImmediatePinVault;

void main() {
  for (final successful in [true, false]) {
    testWidgets('hidden biometric prompt after PIN; success=$successful', (tester) async {
      final biometrics = ControlledBiometrics();
      final lock = LockController(ImmediatePinVault(), biometrics: biometrics)
        ..hasPin = true
        ..biometricsEnabled = true;
      final router = GoRouter(routes: [
        GoRoute(path: '/', builder: (_, _) => CalculatorScreen(lock: lock)),
        GoRoute(path: '/chats', builder: (_, _) => const Scaffold(body: Text('Private content'))),
      ]);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      expect(find.byIcon(Icons.fingerprint), findsNothing);
      expect(find.byTooltip('Device authentication'), findsNothing);
      for (final key in ['2', '5', '8', '0']) {
        await tester.tap(find.text(key).last);
        await tester.pump();
      }
      expect(biometrics.requests, isEmpty);
      await tester.tap(find.text('='));
      await tester.pump();
      expect(biometrics.requests.length, 1);
      expect(find.text('2580'), findsOneWidget);
      expect(find.text('Private content'), findsNothing);
      expect(lock.unlocked, isFalse);
      biometrics.requests.single.complete(successful);
      await tester.pumpAndSettle();
      expect(lock.unlocked, successful);
      expect(find.text('Private content'), successful ? findsOneWidget : findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      lock.dispose();
    });
  }

  testWidgets('incorrect PIN stays an ordinary calculation without biometrics', (tester) async {
    final biometrics = ControlledBiometrics();
    final lock = LockController(ImmediatePinVault(), biometrics: biometrics)
      ..hasPin = true
      ..biometricsEnabled = true;
    await tester.pumpWidget(MaterialApp(home: CalculatorScreen(lock: lock)));
    for (final key in ['9', '9', '9', '9', '=']) {
      await tester.tap(find.text(key).last);
      await tester.pump();
    }
    expect(find.text('9999'), findsOneWidget);
    expect(biometrics.requests, isEmpty);
    expect(lock.unlocked, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    lock.dispose();
  });

  testWidgets('leaving calculator cancels pending biometrics and ignores success', (tester) async {
    final biometrics = ControlledBiometrics();
    final lock = LockController(ImmediatePinVault(), biometrics: biometrics)
      ..hasPin = true
      ..biometricsEnabled = true;
    await tester.pumpWidget(MaterialApp(home: CalculatorScreen(lock: lock)));
    for (final key in ['2', '5', '8', '0', '=']) {
      await tester.tap(find.text(key).last);
      await tester.pump();
    }
    expect(biometrics.requests.length, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    biometrics.requests.single.complete(true);
    await tester.pump();
    expect(lock.unlocked, isFalse);
    expect(biometrics.cancellations, greaterThan(0));
    expect(tester.takeException(), isNull);
    lock.dispose();
  });

  testWidgets(
    'pending numeric result looks normal and keys cancel late unlock',
    (tester) async {
      final pending = PendingVault();
      final lock = LockController(pending)..hasPin = true;
      await tester.pumpWidget(MaterialApp(home: CalculatorScreen(lock: lock)));
      for (final key in ['2', '5', '8', '0', '=']) {
        await tester.tap(find.text(key).last);
        await tester.pump();
      }
      expect(find.text('2580'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(lock.unlocked, isFalse);
      // A normal chained calculation remains responsive while the KDF awaits.
      for (final key in ['+', '1', '=']) {
        await tester.tap(find.text(key).last);
        await tester.pump();
      }
      expect(find.text('2581'), findsOneWidget);
      pending.verification.complete(true);
      await tester.pumpAndSettle();
      expect(lock.unlocked, isFalse);
      expect(tester.takeException(), isNull);
      lock.dispose();
    },
  );

  testWidgets('leaving calculator during verification cannot unlock later', (
    tester,
  ) async {
    final pending = PendingVault();
    final lock = LockController(pending)..hasPin = true;
    await tester.pumpWidget(MaterialApp(home: CalculatorScreen(lock: lock)));
    for (final key in ['2', '5', '8', '0', '=']) {
      await tester.tap(find.text(key).last);
      await tester.pump();
    }
    await tester.pumpWidget(const SizedBox.shrink());
    pending.verification.complete(true);
    await tester.pump();
    expect(lock.unlocked, isFalse);
    expect(tester.takeException(), isNull);
    lock.dispose();
  });
  testWidgets('calculator computes without opening private routes', (
    tester,
  ) async {
    final lock = LockController(PinVault(MemorySecrets(), iterations: 1000));
    await lock.initialize();
    await tester.pumpWidget(MaterialApp(home: CalculatorScreen(lock: lock)));
    for (final key in ['2', '+', '3', '=']) {
      await tester.tap(find.text(key));
      await tester.pumpAndSettle();
    }
    expect(find.text('5'), findsNWidgets(2));
    expect(lock.unlocked, isFalse);
    lock.dispose();
  });
  testWidgets(
    'cold controller starts locked and return to calculator hides private content',
    (tester) async {
      final store = MemorySecrets();
      final vault = PinVault(store, iterations: 1000);
      await tester.runAsync(() => vault.configure('258012'));
      final lock = LockController(vault);
      await lock.initialize();
      expect(lock.unlocked, isFalse);
      final router = GoRouter(
        initialLocation: '/',
        refreshListenable: lock,
        redirect: (_, state) =>
            state.uri.path == '/chats' && !lock.unlocked ? '/' : null,
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => CalculatorScreen(lock: lock),
          ),
          GoRoute(
            path: '/chats',
            builder: (_, _) => const Scaffold(body: Text('Private content')),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      router.go('/chats');
      await tester.pumpAndSettle();
      expect(find.text('Private content'), findsNothing);
      final unlocked = await tester.runAsync(() => lock.unlock('258012'));
      expect(unlocked, isTrue);
      router.go('/chats');
      await tester.pumpAndSettle();
      expect(find.text('Private content'), findsOneWidget);
      lock.lock();
      await tester.pumpAndSettle();
      expect(find.text('Private content'), findsNothing);
      router.dispose();
      lock.dispose();
    },
  );
  testWidgets(
    'chained results and operand sign toggling follow calculator behavior',
    (tester) async {
      final lock = LockController(PinVault(MemorySecrets(), iterations: 1000));
      await tester.pumpWidget(MaterialApp(home: CalculatorScreen(lock: lock)));
      for (final key in ['2', '+', '3', '=', '+', '4', '=']) {
        await tester.tap(find.text(key));
        await tester.pumpAndSettle();
      }
      expect(find.text('9'), findsNWidgets(2));
      for (final key in ['AC', '5', '+', '2', '±', '=']) {
        await tester.tap(find.text(key));
        await tester.pumpAndSettle();
      }
      expect(find.text('3'), findsNWidgets(2));
      lock.dispose();
    },
  );

  testWidgets('landscape calculator lays out without overflow', (tester) async {
    tester.view.physicalSize = const Size(900, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final lock = LockController(PinVault(MemorySecrets(), iterations: 1000));
    await tester.pumpWidget(MaterialApp(home: CalculatorScreen(lock: lock)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('='), findsOneWidget);
    lock.dispose();
  });
  testWidgets(
    'keypad handles backspace, decimal, percent, clear and invalid division',
    (tester) async {
      final lock = LockController(PinVault(MemorySecrets(), iterations: 1000));
      await tester.pumpWidget(MaterialApp(home: CalculatorScreen(lock: lock)));
      Future<void> keys(List<String> values) async {
        for (final value in values) {
          await tester.tap(find.text(value).last);
          await tester.pumpAndSettle();
        }
      }

      await keys(['1', '2', '⌫', '+', '3', '=']);
      expect(find.text('4'), findsNWidgets(2));
      await keys(['AC', '8', '÷', '0', '=']);
      expect(find.text('Error'), findsOneWidget);
      await keys(['AC', '1', '.', '5', '×', '2', '=']);
      expect(find.text('3'), findsNWidgets(2));
      await keys(['AC', '5', '0', '%', '=']);
      expect(find.text('0.5'), findsOneWidget);
      lock.dispose();
    },
  );
}
