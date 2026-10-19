import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:calculator_messenger/core/security/lock_controller.dart';
import 'package:calculator_messenger/features/calculator/calculator_screen.dart';
import 'lock_biometric_test.dart' show ImmediatePinVault;
import 'preview_app_test.dart' show PendingVault;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Calculator 100-cycle unlocking & rapid tap regression tests', () {
    testWidgets('100 consecutive lock and unlock cycles via Calculator UI', (tester) async {
      final vault = ImmediatePinVault();
      final lock = LockController(vault)
        ..hasPin = true
        ..biometricsEnabled = false;

      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (_, _) => CalculatorScreen(lock: lock)),
          GoRoute(
            path: '/chats',
            builder: (_, _) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () {
                    lock.lock();
                  },
                  child: const Text('Lock App'),
                ),
              ),
            ),
          ),
        ],
      );

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      for (int cycle = 1; cycle <= 100; cycle++) {
        expect(lock.unlocked, isFalse, reason: 'Cycle $cycle should start locked');

        // Enter PIN: 2580
        for (final digit in ['2', '5', '8', '0']) {
          await tester.tap(find.text(digit).last);
          await tester.pump();
        }

        // Tap '=' to unlock
        await tester.tap(find.text('=').last);
        await tester.pumpAndSettle();

        expect(lock.unlocked, isTrue, reason: 'Cycle $cycle should unlock');
        expect(find.text('Lock App'), findsOneWidget, reason: 'Cycle $cycle navigated to /chats');

        // Re-lock
        lock.lock();
        router.go('/');
        await tester.pumpAndSettle();

        expect(lock.unlocked, isFalse, reason: 'Cycle $cycle should be locked after relock');
        expect(lock.authenticating, isFalse, reason: 'authenticating flag must be false');
      }

      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      lock.dispose();
    });

    testWidgets('Rapid double tap on = does not clear expression or cancel unlock', (tester) async {
      final pending = PendingVault();
      final lock = LockController(pending)
        ..hasPin = true
        ..biometricsEnabled = false;

      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (_, _) => CalculatorScreen(lock: lock)),
          GoRoute(path: '/chats', builder: (_, _) => const Scaffold(body: Text('Unlocked Chat List'))),
        ],
      );

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      // Enter PIN: 2580
      for (final digit in ['2', '5', '8', '0']) {
        await tester.tap(find.text(digit).last);
        await tester.pump();
      }

      // First '=' tap triggers unlock verification; verification is pending and screen is busy
      await tester.tap(find.text('=').last);
      await tester.pump();
      expect(lock.unlocked, isFalse);

      // Rapid second '=' tap while busy must be ignored safely without canceling or clearing
      await tester.tap(find.text('=').last);
      await tester.pump();

      // Complete verification
      pending.verification.complete(true);
      await tester.pumpAndSettle();

      expect(lock.unlocked, isTrue, reason: 'App must unlock despite rapid double = tap');
      expect(find.text('Unlocked Chat List'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      lock.dispose();
    });

    test('100 consecutive LockController unlock and lock cycles with cancellations', () async {
      final vault = ImmediatePinVault();
      final lock = LockController(vault)
        ..hasPin = true
        ..biometricsEnabled = false;

      for (int i = 1; i <= 100; i++) {
        // Unlock
        final success = await lock.unlock('2580');
        expect(success, isTrue, reason: 'Unlock should succeed in cycle $i');
        expect(lock.unlocked, isTrue);
        expect(lock.authenticating, isFalse);

        // Cancel / Relock
        lock.lock();
        expect(lock.unlocked, isFalse);
        expect(lock.authenticating, isFalse);
      }

      lock.dispose();
    });
  });
}
