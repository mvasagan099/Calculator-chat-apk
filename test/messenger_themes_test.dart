import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:calculator_messenger/core/theme/app_theme.dart';
import 'package:calculator_messenger/core/services/device_settings.dart';
import 'package:calculator_messenger/core/security/lock_controller.dart';
import 'package:calculator_messenger/core/widgets/privacy_gate.dart';
import 'package:calculator_messenger/features/calculator/calculator_screen.dart';
import 'package:calculator_messenger/features/messaging/chat_backdrop.dart';
import 'lock_biometric_test.dart' show ImmediatePinVault;

void main() {
  for (final brightness in Brightness.values) {
    for (final variant in MessengerTheme.values) {
      testWidgets('${variant.label} supports ${brightness.name} without altering calculator', (tester) async {
        final lock = LockController(ImmediatePinVault());
        final base = AppTheme.build(brightness);
        final messenger = AppTheme.messenger(brightness, variant);
        expect(messenger.brightness, brightness);
        if (variant == MessengerTheme.defaultTheme) expect(messenger.colorScheme, base.colorScheme);
        await tester.pumpWidget(MaterialApp(theme: base, home: Column(children: [
          Expanded(child: CalculatorScreen(lock: lock)),
          Theme(data: messenger, child: const ChatBackdrop(style: 'plain', child: Text('Private preview'))),
        ])));
        final calculator = tester.element(find.byType(CalculatorScreen));
        expect(Theme.of(calculator).colorScheme, base.colorScheme);
        expect(find.byIcon(Icons.fingerprint), findsNothing);
        expect(find.text('='), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink()); lock.dispose();
      }, timeout: const Timeout(Duration(minutes: 2)));
    }
  }
  test('messenger style and appearance persist independently of calculator theme', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final lock = LockController(ImmediatePinVault());
    final first = DeviceSettings(preferences, lock);
    expect(first.messengerTheme, MessengerTheme.defaultTheme);
    final original = first.theme;
    await first.setMessengerTheme(MessengerTheme.instagramLike);
    await first.setMessengerAppearance(ThemeMode.dark);
    final restarted = DeviceSettings(preferences, lock);
    expect(restarted.messengerTheme, MessengerTheme.instagramLike);
    expect(restarted.messengerAppearance, ThemeMode.dark);
    expect(restarted.theme, original);
    await restarted.setMessengerTheme(MessengerTheme.telegramLike);
    expect(DeviceSettings(preferences, lock).messengerTheme, MessengerTheme.telegramLike);
    lock.dispose(); first.dispose(); restarted.dispose();
  });
  testWidgets('relocking a themed private route renders the original calculator theme', (tester) async {
    final lock = LockController(ImmediatePinVault());
    final baseline = AppTheme.build(Brightness.light);
    await tester.pumpWidget(MaterialApp(theme: AppTheme.messenger(Brightness.dark, MessengerTheme.instagramLike), home: PrivacyGate(
      lock: lock, authenticated: () => true, authChanges: lock, calculatorTheme: baseline,
      child: const Text('Private content'),
    )));
    expect(find.text('Private content'), findsNothing);
    expect(Theme.of(tester.element(find.byType(CalculatorScreen))).colorScheme, baseline.colorScheme);
    await tester.pumpWidget(const SizedBox.shrink()); lock.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
  test('unknown stored style safely falls back to Default', () async {
    SharedPreferences.setMockInitialValues({'messenger.theme': 'future'});
    final lock = LockController(ImmediatePinVault());
    final device = DeviceSettings(await SharedPreferences.getInstance(), lock);
    expect(device.messengerTheme, MessengerTheme.defaultTheme);
    device.dispose(); lock.dispose();
  });
}
