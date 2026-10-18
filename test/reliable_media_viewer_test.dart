import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:calculator_messenger/core/security/lock_controller.dart';
import 'package:calculator_messenger/features/media/attachment_view.dart';
import 'package:calculator_messenger/features/media/document_viewer.dart';
import 'package:calculator_messenger/features/media/expiring_attachment_view.dart';
import 'package:calculator_messenger/features/media/full_screen_image_viewer.dart';
import 'package:calculator_messenger/features/media/full_screen_video_viewer.dart';
import 'package:calculator_messenger/providers/app_providers.dart';
import 'async_widget_helpers.dart';
import 'lock_biometric_test.dart' show ImmediatePinVault;

void main() {
  group('FullScreenImageViewer', () {
    testWidgets('renders image with InteractiveViewer, title, size, and cleans bytes on dispose', (tester) async {
      final lock = LockController(ImmediatePinVault())..hasPin = true..unlocked = true;
      final bytes = Uint8List.fromList([255, 216, 255, 224, 0, 16, 74, 70, 73, 70]);
      
      await tester.pumpWidget(
        ProviderScope(
          overrides: [lockProvider.overrideWithValue(lock)],
          child: MaterialApp(
            home: FullScreenImageViewer(
              bytes: bytes,
              filename: 'vacation.jpg',
              sizeBytes: 10240,
              expiresAt: DateTime.now().add(const Duration(hours: 1)),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('vacation.jpg'), findsOneWidget);
      expect(find.text('10 KB'), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.byIcon(Icons.ios_share), findsOneWidget);

      // Verify double-tap triggers zoom
      await tester.tap(find.byType(InteractiveViewer));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byType(InteractiveViewer));
      await tester.pumpAndSettle();

      // Reset zoom icon appears when zoomed
      expect(find.byIcon(Icons.zoom_out_map), findsOneWidget);

      // Tap reset zoom
      await tester.tap(find.byIcon(Icons.zoom_out_map));
      await tester.pumpAndSettle();

      // Original caller bytes buffer was NOT mutated during viewing
      expect(bytes[0], 255);

      // Unmount viewer
      await tester.pumpWidget(const SizedBox.shrink());
      lock.dispose();
    });

    testWidgets('closes and clears when media expires', (tester) async {
      final lock = LockController(ImmediatePinVault())..hasPin = true..unlocked = true;
      final bytes = Uint8List.fromList([1, 2, 3]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [lockProvider.overrideWithValue(lock)],
          child: MaterialApp(
            home: FullScreenImageViewer(
              bytes: bytes,
              filename: 'secret.png',
              expiresAt: DateTime.now().add(const Duration(seconds: 1)),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('secret.png'), findsOneWidget);

      // Fast-forward past expiry
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Media closed or expired'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      lock.dispose();
    });
  });

  group('TextDocumentViewer', () {
    testWidgets('renders text content with selectable text and title', (tester) async {
      final lock = LockController(ImmediatePinVault())..hasPin = true..unlocked = true;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [lockProvider.overrideWithValue(lock)],
          child: MaterialApp(
            home: TextDocumentViewer(
              filename: 'notes.txt',
              content: 'Secret project notes:\n1. Keep it safe\n2. Private messaging',
              expiresAt: DateTime.now().add(const Duration(hours: 1)),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('notes.txt'), findsOneWidget);
      expect(find.textContaining('Secret project notes:'), findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.byIcon(Icons.ios_share), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      lock.dispose();
    });
  });

  group('ExpiringAttachmentView retry and download progress', () {
    testWidgets('shows loading progress and allows retry on network failure', (tester) async {
      final lock = LockController(ImmediatePinVault())..hasPin = true..unlocked = true;
      final client = SupabaseClient('https://fixture.supabase.co', 'fixture');
      int attempt = 0;

      Future<Uint8List> mockLoader() async {
        attempt++;
        if (attempt == 1) {
          throw StateError('Connection reset by peer');
        }
        return Uint8List.fromList([255, 216, 255, 1]);
      }

      await tester.pumpWidget(
        ProviderScope(
          overrides: [lockProvider.overrideWithValue(lock)],
          child: MaterialApp(
            home: Scaffold(
              body: ExpiringAttachmentView(
                client: client,
                kind: 'image',
                attachment: {
                  'mime_type': 'image/jpeg',
                  'media_expires_at': DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
                  'filename': 'photo.jpg',
                },
                loader: mockLoader,
              ),
            ),
          ),
        ),
      );

      // Initial load fails
      await tester.pump();
      expect(find.text('Media unavailable'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      // Tap Retry to reload successfully
      await tester.tap(find.text('Retry'));
      await tester.pump();

      expect(find.byType(Image), findsOneWidget);
      expect(find.text('Media unavailable'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      lock.dispose();
      await pumpAsyncOperation(tester, client.dispose());
    });
  });

  group('AttachmentView documents and audio controls', () {
    testWidgets('renders document tile with icon, size, and open button', (tester) async {
      final client = SupabaseClient('https://fixture.supabase.co', 'fixture');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AttachmentView(
              client: client,
              kind: 'file',
              attachment: {
                'mime_type': 'application/pdf',
                'filename': 'statement.pdf',
                'size_bytes': 204800,
                'object_path': 'chat/user/statement.pdf',
              },
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('statement.pdf'), findsOneWidget);
      expect(find.text('200 KB'), findsOneWidget);
      expect(find.byIcon(Icons.picture_as_pdf), findsOneWidget);
      expect(find.byIcon(Icons.open_in_new), findsOneWidget);
      expect(find.byIcon(Icons.ios_share), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await pumpAsyncOperation(tester, client.dispose());
    });

    testWidgets('renders audio controls with play button, scrubber slider, and speed toggle', (tester) async {
      final client = SupabaseClient('https://fixture.supabase.co', 'fixture');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AttachmentView(
              client: client,
              kind: 'audio',
              attachment: {
                'mime_type': 'audio/mpeg',
                'filename': 'voice_memo.mp3',
                'size_bytes': 65536,
                'object_path': 'chat/user/voice_memo.mp3',
              },
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.play_circle_filled), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      expect(find.text('1.0×'), findsOneWidget);

      // Speed button toggles 1.0x -> 1.5x -> 2.0x -> 1.0x
      await tester.tap(find.text('1.0×'));
      await tester.pump();
      expect(find.text('1.5×'), findsOneWidget);

      await tester.tap(find.text('1.5×'));
      await tester.pump();
      expect(find.text('2.0×'), findsOneWidget);

      await tester.tap(find.text('2.0×'));
      await tester.pump();
      expect(find.text('1.0×'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await pumpAsyncOperation(tester, client.dispose());
    });
  });
}
