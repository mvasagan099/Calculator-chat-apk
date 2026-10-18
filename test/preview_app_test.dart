import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:calculator_messenger/core/security/lock_controller.dart';
import 'package:calculator_messenger/core/security/pin_vault.dart';
import 'package:calculator_messenger/core/security/pin_performance.dart';
import 'package:calculator_messenger/core/services/device_settings.dart';
import 'package:calculator_messenger/features/calculator/calculator_screen.dart';
import 'package:calculator_messenger/features/preview/preview_app.dart';
import 'package:calculator_messenger/providers/app_providers.dart';
import 'pin_vault_test.dart' show MemorySecrets;

class PendingVault extends PinVault {
  PendingVault() : super(MemorySecrets());
  final verification = Completer<bool>();
  @override
  Future<bool> verify(String pin, {PinTrace? trace}) => verification.future;
}

class FailingStore extends MemorySecrets {
  @override
  Future<void> write(String key, String value) async =>
      throw StateError('Keystore unavailable');
}

void main() {
  late MemorySecrets store;
  late PinVault vault;
  late LockController lock;
  late DeviceSettings device;
  bool mounted = false;
  void previewTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      mounted = false;
      try {
        await body(tester);
      } finally {
        if (mounted) {
          lock.lock();
          await tester.pumpWidget(const SizedBox.shrink());
          lock.dispose();
          device.dispose();
        }
      }
    });
  }

  Future<void> saveButton(WidgetTester tester) async {
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    final save = find.widgetWithText(FilledButton, 'Save PIN and open calculator');
    // Scrolling until the text enters the ListView is insufficient if the
    // keyboard has reduced the root viewport; bring the button itself onscreen.
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
  }

  Future<void> mount(
    WidgetTester tester, {
    bool configured = true,
    MemorySecrets? secrets,
  }) async {
    SharedPreferences.setMockInitialValues({});
    store = secrets ?? MemorySecrets();
    vault = PinVault(store, iterations: 1000, storageKey: PinVault.previewKey);
    if (configured) await tester.runAsync(() => vault.configure('2580'));
    lock = LockController(vault);
    await lock.initialize();
    device = DeviceSettings(
      await SharedPreferences.getInstance(),
      lock,
      keyPrefix: 'preview.',
    );
    await device.initialize();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          lockProvider.overrideWithValue(lock),
          supabaseProvider.overrideWith(
            (ref) => throw StateError('Preview must not touch Supabase'),
          ),
        ],
        child: PreviewApp(lock: lock, device: device),
      ),
    );
    await tester.pumpAndSettle();
    mounted = true;
  }

  Future<void> keys(WidgetTester tester, List<String> values) async {
    for (final value in values) {
      await tester.tap(find.text(value).last);
      if (value == '=') {
        await tester.runAsync(() async {
          for (var i = 0; i < 200 && lock.authenticating; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        });
      }
      await tester.pumpAndSettle();
    }
  }

  Future<void> unlock(WidgetTester tester) =>
      keys(tester, ['2', '5', '8', '0', '=']);

  previewTest(
    'first launch confirms and persists PIN then returns to calculator',
    (tester) async {
      await mount(tester, configured: false);
      expect(find.text('A little space of your own'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'New PIN'),
        '2580',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Confirm PIN'),
        '2581',
      );
      await saveButton(tester);
      await tester.tap(find.text('Save PIN and open calculator'));
      await tester.pumpAndSettle();
      expect(find.text('PINs do not match'), findsOneWidget);
      expect(await vault.configured, isFalse);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Confirm PIN'),
        '2580',
      );
      await saveButton(tester);
      await tester.runAsync(() async {
        await tester.tap(find.text('Save PIN and open calculator'));
        for (var i = 0; i < 200 && !lock.hasPin; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      await tester.pumpAndSettle();
      expect(find.text('Calculator'), findsOneWidget);
      expect(lock.unlocked, isFalse);
      expect(
        await tester.runAsync(
          () => PinVault(
            store,
            iterations: 1000,
            storageKey: PinVault.previewKey,
          ).verify('2580'),
        ),
        isTrue,
      );
      expect(store.values[PinVault.recordKey], isNull);
      await unlock(tester);
      expect(find.text('Your space'), findsOneWidget);
    },
  );

  previewTest(
    'incorrect four digit PIN stays calculator; correct PIN unlocks local fixtures',
    (tester) async {
      await mount(tester);
      await keys(tester, ['1', '2', '3', '4', '=']);
      expect(find.text('1234'), findsOneWidget);
      expect(find.text('Maya Chen'), findsNothing);
      expect(lock.unlocked, isFalse);
      await keys(tester, ['AC', '2', '5', '0', '0', '+', '8', '0', '=']);
      expect(find.text('2580'), findsOneWidget);
      expect(lock.unlocked, isFalse);
      await unlock(tester);
      expect(find.text('Maya Chen'), findsOneWidget);
      expect(find.textContaining('LOCAL PREVIEW'), findsOneWidget);
      expect(find.text('Your space'), findsOneWidget);
    },
  );

  previewTest(
    'all messenger tabs, profile, search, conversation and theme work without backend',
    (tester) async {
      await mount(tester);
      await unlock(tester);
      await tester.enterText(find.byType(TextField).first, 'arjun');
      await tester.pumpAndSettle();
      expect(find.text('Maya Chen'), findsNothing);
      await tester.tap(find.text('Arjun Patel'));
      await tester.pumpAndSettle();
      expect(
        find.text('I’m trying out the chat layout today.'),
        findsOneWidget,
      );
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      await tester.pageBack();
      await tester.pumpAndSettle();
      for (final tab in ['Updates', 'Calls', 'Groups', 'Settings']) {
        await tester.tap(find.text(tab).last);
        await tester.pumpAndSettle();
        expect(find.textContaining('LOCAL PREVIEW'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.byType(DropdownButton<ThemeMode>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dark').last);
      await tester.pumpAndSettle();
      expect(device.theme, ThemeMode.dark);
      await tester.tap(find.text('Preview Owner'));
      await tester.pumpAndSettle();
      expect(find.text('Your profile'), findsOneWidget);
      expect(find.text('Local development profile'), findsOneWidget);
    },
  );

  previewTest(
    'deep link stays locked and resumes only after PIN; background and back cannot expose it',
    (tester) async {
      await mount(tester);
      final router = GoRouter.of(
        tester.element(find.byType(CalculatorScreen).last),
      );
      router.go('/chat/maya');
      await tester.pumpAndSettle();
      expect(find.text('Maya Chen'), findsNothing);
      await unlock(tester);
      expect(find.text('Maya Chen'), findsOneWidget);
      lock.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(find.text('Maya Chen'), findsNothing);
      expect(find.text('Calculator'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Maya Chen'), findsNothing);
      lock.didChangeAppLifecycleState(AppLifecycleState.resumed);
      router.go('/chats');
      await tester.pumpAndSettle();
      await unlock(tester);
      router.go('/chats');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Quick Lock (Return to Calculator)'));
      await tester.pumpAndSettle();
      expect(find.text('Maya Chen'), findsNothing);
      expect(lock.unlocked, isFalse);
    },
  );

  previewTest('recreated app retains PIN but cold launches locked', (
    tester,
  ) async {
    await mount(tester);
    await unlock(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    lock.dispose();
    device.dispose();
    // mount registers teardown against the current variables, so only the new
    // controller remains owned by it after simulating process recreation.
    lock = LockController(
      PinVault(store, iterations: 1000, storageKey: PinVault.previewKey),
    );
    await lock.initialize();
    device = DeviceSettings(
      await SharedPreferences.getInstance(),
      lock,
      keyPrefix: 'preview.',
    );
    await device.initialize();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [lockProvider.overrideWithValue(lock)],
        child: PreviewApp(lock: lock, device: device),
      ),
    );
    await tester.pumpAndSettle();
    expect(lock.hasPin, isTrue);
    expect(lock.unlocked, isFalse);
    expect(find.text('Calculator'), findsOneWidget);
    expect(find.text('Maya Chen'), findsNothing);
  });

  previewTest('failed secure write keeps onboarding protected', (tester) async {
    await mount(tester, configured: false, secrets: FailingStore());
    await tester.enterText(
      find.widgetWithText(TextFormField, 'New PIN'),
      '2580',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Confirm PIN'),
      '2580',
    );
    await saveButton(tester);
    await tester.runAsync(() async {
      await tester.tap(find.text('Save PIN and open calculator'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(lock.hasPin, isFalse);
    expect(lock.unlocked, isFalse);
    expect(
      find.text('PIN could not be saved securely. Please try again.'),
      findsOneWidget,
    );
    expect(find.text('Maya Chen'), findsNothing);
  });

  previewTest('small and landscape messenger layouts do not overflow', (
    tester,
  ) async {
    await mount(tester);
    await unlock(tester);
    for (final size in [const Size(320, 568), const Size(900, 360)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  previewTest('background invalidates an in-flight PIN verification', (
    tester,
  ) async {
    final pending = PendingVault();
    final controller = LockController(pending)..hasPin = true;
    final opening = controller.unlock('2580');
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    pending.verification.complete(true);
    expect(await opening, isFalse);
    expect(controller.unlocked, isFalse);
    controller.dispose();
  });

  previewTest('manual relock and disposal invalidate late PIN results', (
    tester,
  ) async {
    for (final dispose in [false, true]) {
      final pending = PendingVault();
      final controller = LockController(pending)..hasPin = true;
      final opening = controller.unlock('2580');
      if (dispose) {
        controller.dispose();
      } else {
        controller.lock();
      }
      pending.verification.complete(true);
      expect(await opening, isFalse);
      expect(controller.unlocked, isFalse);
      if (!dispose) controller.dispose();
    }
  });
}
