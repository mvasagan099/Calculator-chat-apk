import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:calculator_messenger/features/media/view_once_viewer.dart';
import 'package:calculator_messenger/models/message.dart';
import 'package:calculator_messenger/core/security/lock_controller.dart';
import 'package:calculator_messenger/core/security/pin_vault.dart';
import 'package:calculator_messenger/providers/app_providers.dart';
import 'pin_vault_test.dart' show MemorySecrets;

void main() {
  for (final mode in [
    'displayed content',
    'a pending opening',
    'expired content',
  ]) {
    final delayed = mode == 'a pending opening';
    final expiry = mode == 'expired content';
    testWidgets('Transport adapter: view-once closes $mode permanently', (
      tester,
    ) async {
      final lock = LockController(PinVault(MemorySecrets(), iterations: 1000));
      lock.hasPin = true;
      lock.unlocked = true;
      final response = Completer<void>();
      var requests = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [lockProvider.overrideWithValue(lock)],
          child: MaterialApp(
            home: ViewOnceViewer(
              loader: (id, abort) async {
                requests++;
                if (delayed) await response.future;
                return File('test/fixtures/hosted-pixel.png').readAsBytesSync();
              },
              message: ChatMessage(
                id: '81000000-0000-0000-0000-000000000001',
                conversationId: 'chat',
                senderId: 'peer',
                body: '',
                kind: 'image',
                createdAt: DateTime.now(),
                expiresAt: expiry
                    ? DateTime.now().add(const Duration(seconds: 1))
                    : null,
                viewOnce: true,
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(requests, 1);
      if (!delayed) expect(find.byType(Image), findsOneWidget);
      if (expiry) {
        await tester.pump(const Duration(seconds: 2));
      } else {
        lock.lock();
      }
      await tester.pump();
      if (delayed) {
        response.complete();
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
      }
      expect(find.byType(Image), findsNothing);
      expect(
        find.text('Closed. This media cannot be reopened here.'),
        findsOneWidget,
      );
      lock.unlocked = true;
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect(requests, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      lock.dispose();
    });
  }
}
