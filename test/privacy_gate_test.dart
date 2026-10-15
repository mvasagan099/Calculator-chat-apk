import 'package:flutter/material.dart';
import 'package:calculator_messenger/core/widgets/privacy_mask.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:calculator_messenger/core/widgets/privacy_gate.dart';
import 'package:calculator_messenger/core/security/lock_controller.dart';
import 'package:calculator_messenger/core/security/pin_vault.dart';
import 'pin_vault_test.dart' show MemorySecrets;

void main() {
  testWidgets(
    'private subtree is never mounted without both independent gates',
    (tester) async {
      final lock = LockController(PinVault(MemorySecrets(), iterations: 1000));
      final auth = ValueNotifier(false);
      lock.hasPin = true;
      await tester.pumpWidget(
        MaterialApp(
          home: PrivacyGate(
            lock: lock,
            authenticated: () => auth.value,
            authChanges: auth,
            child: const Text('Sensitive conversation'),
          ),
        ),
      );
      expect(find.text('Sensitive conversation'), findsNothing);
      auth.value = true;
      await tester.pump();
      expect(find.text('Sensitive conversation'), findsNothing);
      lock.unlocked = true;
      lock.touch();
      auth.notifyListeners();
      await tester.pump();
      expect(find.text('Sensitive conversation'), findsOneWidget);
      lock.lock();
      await tester.pump();
      expect(find.text('Sensitive conversation'), findsNothing);
      lock.unlocked = true;
      auth.value = false;
      await tester.pump();
      expect(find.text('Sensitive conversation'), findsNothing);
      lock.dispose();
      auth.dispose();
    },
  );
  testWidgets('background and inactivity close the lock', (tester) async {
    final lock = LockController(PinVault(MemorySecrets(), iterations: 1000));
    lock.hasPin = true;
    lock.unlocked = true;
    lock.didChangeAppLifecycleState(AppLifecycleState.inactive);
    expect(lock.unlocked, isFalse);
    lock.unlocked = true;
    lock.timeout = const Duration(seconds: 30);
    lock.touch();
    await tester.pump(const Duration(seconds: 31));
    expect(lock.unlocked, isFalse);
    lock.dispose();
  });
  testWidgets(
    'root privacy mask hides dialogs retained in the private navigator',
    (tester) async {
      final locked = ValueNotifier(false);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => ValueListenableBuilder<bool>(
            valueListenable: locked,
            builder: (context, value, _) => PrivacyMask(
              locked: value,
              publicSurface: const Material(child: Text('Calculator cover')),
              child: child!,
            ),
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const AlertDialog(
                    content: Text('Private modal contents'),
                  ),
                ),
                child: const Text('Open private modal'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open private modal'));
      await tester.pumpAndSettle();
      expect(find.text('Private modal contents'), findsOneWidget);
      locked.value = true;
      await tester.pump();
      expect(find.text('Private modal contents'), findsNothing);
      expect(find.text('Calculator cover'), findsOneWidget);
      locked.dispose();
    },
  );
}
