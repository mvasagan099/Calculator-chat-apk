import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:calculator_messenger/core/security/lock_controller.dart';
import 'package:calculator_messenger/core/security/pin_vault.dart';
import 'package:calculator_messenger/features/calculator/calculator_screen.dart';
import 'pin_vault_test.dart' show MemorySecrets;

void main() {
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
