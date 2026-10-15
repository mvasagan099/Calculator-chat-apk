import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:calculator_messenger/main.dart';
import 'package:calculator_messenger/core/security/lock_controller.dart';
import 'package:calculator_messenger/core/security/pin_vault.dart';
import 'package:calculator_messenger/core/services/auth_service.dart';
import 'package:calculator_messenger/core/services/device_settings.dart';
import 'package:calculator_messenger/features/notifications/notification_service.dart';
import 'package:calculator_messenger/providers/app_providers.dart';
import 'pin_vault_test.dart' show MemorySecrets;

void main() {
  testWidgets(
    'locked app can navigate onboarding without mounting a private screen',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = MemorySecrets(),
          lock = LockController(PinVault(MemorySecrets(), iterations: 1000));
      final auth = AuthService(null, lock, store),
          notifications = NotificationService();
      final device = DeviceSettings(
        await SharedPreferences.getInstance(),
        lock,
      );
      await device.initialize();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [lockProvider.overrideWithValue(lock)],
          child: MessengerApp(
            auth: auth,
            device: device,
            notifications: notifications,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Your space'), findsNothing);
      await tester.tap(find.text('Set up'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Backend not configured. Follow docs/DEPLOYMENT.md and build with SUPABASE_URL and SUPABASE_ANON_KEY. Calculator functions remain available.',
        ),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.text('Return to Calculator'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.drag(find.byType(ListView).first, const Offset(0, -120));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Return to Calculator'));
      await tester.pumpAndSettle();
      expect(find.text('Set up'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      auth.dispose();
      lock.dispose();
      notifications.dispose();
      device.dispose();
    },
  );
}
