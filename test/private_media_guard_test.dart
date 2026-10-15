import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:calculator_messenger/features/media/private_media_guard.dart';
import 'package:calculator_messenger/core/security/lock_controller.dart';
import 'package:calculator_messenger/core/security/pin_vault.dart';
import 'package:calculator_messenger/providers/app_providers.dart';
import 'pin_vault_test.dart' show MemorySecrets;

class Renderer extends StatefulWidget {
  const Renderer({super.key, required this.onDispose});
  final VoidCallback onDispose;
  @override
  State<Renderer> createState() => _RendererState();
}

class _RendererState extends State<Renderer> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Text('sensitive renderer');
}

void main() {
  for (final expiring in [false, true]) {
    testWidgets(
      'retained media renderer is destroyed on ${expiring ? 'expiration' : 'manual relock'}',
      (tester) async {
        final lock = LockController(PinVault(MemorySecrets(), iterations: 1000))
          ..hasPin = true
          ..unlocked = true;
        var disposed = 0;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [lockProvider.overrideWithValue(lock)],
            child: MaterialApp(
              home: PrivateMediaGuard(
                expiresAt: expiring
                    ? DateTime.now().add(const Duration(seconds: 1))
                    : null,
                builder: (_) => Renderer(onDispose: () => disposed++),
              ),
            ),
          ),
        );
        expect(find.text('sensitive renderer'), findsOneWidget);
        if (expiring) {
          await tester.pump(const Duration(seconds: 2));
        } else {
          lock.lock();
          await tester.pump();
        }
        expect(find.text('sensitive renderer'), findsNothing);
        expect(disposed, 1);
        await tester.pumpWidget(const SizedBox.shrink());
        lock.dispose();
      },
    );
  }
}
