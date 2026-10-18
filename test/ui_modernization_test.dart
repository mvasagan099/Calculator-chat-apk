import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:calculator_messenger/core/theme/app_theme.dart';
import 'package:calculator_messenger/core/services/device_settings.dart';
import 'package:calculator_messenger/core/security/lock_controller.dart';
import 'package:calculator_messenger/core/widgets/private_scaffold.dart';
import 'lock_biometric_test.dart' show ImmediatePinVault;

void main() {
  group('UI Modernization & Design System Tests', () {
    test('All theme variants create valid themes for light and dark', () {
      for (final variant in MessengerTheme.values) {
        final lightTheme = AppTheme.messenger(Brightness.light, variant);
        expect(lightTheme.brightness, Brightness.light);
        expect(lightTheme.colorScheme.primary, isNotNull);

        final darkTheme = AppTheme.messenger(Brightness.dark, variant);
        expect(darkTheme.brightness, Brightness.dark);
        expect(darkTheme.colorScheme.primary, isNotNull);
      }
    });

    test('AMOLED mode generates true pitch black surfaces', () {
      final regularDark = AppTheme.build(Brightness.dark, amoled: false);
      final amoledDark = AppTheme.build(Brightness.dark, amoled: true);

      expect(amoledDark.scaffoldBackgroundColor, Colors.black);
      expect(amoledDark.colorScheme.surface, Colors.black);
      expect(amoledDark.cardTheme.color, const Color(0xFF0A0A0A));
      expect(regularDark.scaffoldBackgroundColor != Colors.black, isTrue);
    });

    test('AMOLED mode in messenger theme sets black background', () {
      final amoledMessenger = AppTheme.messenger(
        Brightness.dark,
        MessengerTheme.emerald,
        amoled: true,
      );
      expect(amoledMessenger.scaffoldBackgroundColor, Colors.black);
      expect(amoledMessenger.colorScheme.surface, Colors.black);
    });

    test('DeviceSettings correctly gets, sets, and persists amoledMode', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final lock = LockController(ImmediatePinVault());
      final device = DeviceSettings(preferences, lock);

      expect(device.amoledMode, isFalse);

      bool notified = false;
      device.addListener(() => notified = true);

      await device.setAmoledMode(true);
      expect(device.amoledMode, isTrue);
      expect(notified, isTrue);

      final restarted = DeviceSettings(preferences, lock);
      expect(restarted.amoledMode, isTrue);

      device.dispose();
      restarted.dispose();
      lock.dispose();
    });

    test('AvatarCache properly stores and retrieves memoized signed URLs', () {
      const testPath = 'avatars/user_123.jpg';
      const testUrl = 'https://example.com/storage/v1/object/sign/avatars/user_123.jpg?token=abc';

      AvatarCache.set(testPath, testUrl);
      expect(AvatarCache.get(testPath), testUrl);
      AvatarCache.clear();
      expect(AvatarCache.get(testPath), isNull);
    });
  });
}
