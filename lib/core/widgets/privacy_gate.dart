import 'package:flutter/material.dart';
import '../security/lock_controller.dart';
import '../theme/app_theme.dart';
import '../../features/calculator/calculator_screen.dart';
import 'privacy_mask.dart';

/// Each private route owns a gate, including routes retained during transitions.
class PrivacyGate extends StatelessWidget {
  const PrivacyGate({
    super.key,
    required this.lock,
    required this.authenticated,
    required this.authChanges,
    required this.child,
    this.calculatorTheme,
  });
  final LockController lock;
  final bool Function() authenticated;
  final Listenable authChanges;
  final Widget child;
  final ThemeData? calculatorTheme;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([lock, authChanges]),
    builder: (context, _) {
      if (!lock.unlocked || !lock.hasPin || !authenticated()) {
        return Theme(data: calculatorTheme ?? AppTheme.build(Theme.of(context).brightness), child: CalculatorScreen(lock: lock));
      }
      return PrivacyMask(
        locked: lock.mediaPickerActive,
        publicSurface: const ColoredBox(color: Color(0xFF101010)),
        child: child,
      );
    },
  );
}
