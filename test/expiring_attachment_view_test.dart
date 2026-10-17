import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:calculator_messenger/core/security/lock_controller.dart';
import 'package:calculator_messenger/features/media/expiring_attachment_view.dart';
import 'package:calculator_messenger/providers/app_providers.dart';
import 'lock_biometric_test.dart' show ImmediatePinVault;

void main() {
  for (final event in ['expiry', 'lock', 'background']) {
    testWidgets('late image bytes cannot reappear after $event', (tester) async {
      final lock = LockController(ImmediatePinVault())..hasPin = true..unlocked = true;
      final client = SupabaseClient('https://fixture.supabase.co', 'fixture');
      final pending = Completer<Uint8List>();
      await tester.pumpWidget(ProviderScope(overrides: [lockProvider.overrideWithValue(lock)], child: MaterialApp(
        home: Scaffold(body: ExpiringAttachmentView(client: client, kind: 'image', attachment: {
          'mime_type': 'image/jpeg', 'media_expires_at': DateTime.now().add(const Duration(seconds: 1)).toIso8601String(),
        }, loader: () => pending.future)),
      )));
      if (event == 'expiry') { await tester.pump(const Duration(seconds: 2)); }
      if (event == 'lock') { lock.lock(); await tester.pump(); }
      if (event == 'background') {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
      }
      final bytes = Uint8List.fromList([1, 2, 3]);
      pending.complete(bytes);
      await tester.pump();
      expect(bytes, [0, 0, 0]);
      expect(find.byType(Image), findsNothing);
      expect(find.text('Media expired'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      lock.dispose(); await tester.runAsync(client.dispose);
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
}
