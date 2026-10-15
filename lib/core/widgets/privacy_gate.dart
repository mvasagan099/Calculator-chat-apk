import 'package:flutter/material.dart';
import '../security/lock_controller.dart';
import '../../features/calculator/calculator_screen.dart';

/// Each private route owns a gate, including routes retained during transitions.
class PrivacyGate extends StatelessWidget {
  const PrivacyGate({
    super.key,
    required this.lock,
    required this.authenticated,
    required this.authChanges,
    required this.child,
  });
  final LockController lock;
  final bool Function() authenticated;
  final Listenable authChanges;
  final Widget child;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([lock, authChanges]),
    builder: (context, _) {
      if (!lock.unlocked || !lock.hasPin || !authenticated()) {
        return CalculatorScreen(lock: lock);
      }
      return child;
    },
  );
}
