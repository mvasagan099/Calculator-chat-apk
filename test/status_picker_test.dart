import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:calculator_messenger/core/security/lock_controller.dart';
import 'package:calculator_messenger/core/services/auth_service.dart';
import 'package:calculator_messenger/core/widgets/privacy_gate.dart';
import 'package:calculator_messenger/features/status/status_screen.dart';
import 'package:calculator_messenger/providers/app_providers.dart';
import 'package:calculator_messenger/repositories/messenger_repository.dart';
import 'pin_vault_test.dart' show MemorySecrets;
import 'lock_biometric_test.dart' show ImmediatePinVault;
import 'media_picker_handoff_test.dart' show ControlledMediaPicker;

class MissingMediaFile extends XFile {
  MissingMediaFile() : super('/missing-fixture.jpg');
  @override
  Future<int> length() async => throw const FileSystemException('Selected file no longer exists');
  @override
  Future<Uint8List> readAsBytes() async => throw const FileSystemException('Selected file no longer exists');
}

class StatusFixtureRepository extends MessengerRepository {
  StatusFixtureRepository(super.client);
  @override
  Stream<T> watch<T>(List<String> tables, Future<T> Function() fetch, {String? cid}) =>
      Stream<T>.value(<Map<String, dynamic>>[] as T);
}

class PickerFixtureAuth extends AuthService {
  PickerFixtureAuth(SupabaseClient client, LockController lock)
      : super(client, lock, MemorySecrets()) {
    ownerMatches = true;
    deviceAuthorized = true;
  }
  bool active = true;
  int rechecks = 0;
  @override
  bool get signedIn => active && super.signedIn;
  @override
  Future<void> refreshDeviceAccess({bool initial = false}) async {
    rechecks++;
    if (!active || !deviceAuthorized) lock.lock();
  }
}

void main() {
  for (final outcome in ['image', 'video', 'cancel', 'missing file', 'Home', 'manual lock', 'revoked device', 'expired session', 'repeated launch']) {
    testWidgets('Updates picker: $outcome', (tester) async {
      const owner = '12000000-0000-0000-0000-000000000001';
      const sid = '12000000-0000-0000-0000-000000000002';
      final requests = <String>[];
      String encoded(Object value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
      final client = SupabaseClient('https://fixture.invalid', 'public-fixture',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          requests.add(request.url.path);
          Object response = {};
          if (request.url.path.endsWith('/auth/v1/token')) {
            final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
            response = {
              'access_token': '${encoded({'alg': 'HS256'})}.${encoded({'sub': owner, 'session_id': sid, 'iat': now, 'exp': now + 3600})}.fixture',
              'refresh_token': 'fixture-refresh', 'expires_in': 3600, 'token_type': 'bearer',
              'user': {'id': owner, 'aud': 'authenticated', 'created_at': '2026-01-01T00:00:00Z', 'app_metadata': {}, 'user_metadata': {}},
            };
          } else if (request.url.path.contains('/storage/v1/object/')) {
            response = {'Key': 'status-media/fixture', 'Id': 'fixture'};
          } else if (request.url.path.endsWith('/rpc/create_status')) {
            response = '12000000-0000-0000-0000-000000000003';
          }
          return http.Response(jsonEncode(response), 200, request: request,
              headers: {'content-type': 'application/json'});
        }));
      await tester.runAsync(() => client.auth.setSession('fixture-refresh'));
      final native = ControlledMediaPicker();
      final lock = LockController(ImmediatePinVault(), mediaPicker: native)..hasPin = true;
      final auth = PickerFixtureAuth(client, lock);
      await lock.unlock('2580');
      final selected = Completer<XFile?>();
      var pickerCalls = 0;
      final screen = StatusScreen(mediaPicker: (kind) {
        pickerCalls++;
        expect(kind, outcome == 'video' ? 'video' : 'image');
        return selected.future;
      });
      final repository = StatusFixtureRepository(client);
      await tester.pumpWidget(ProviderScope(overrides: [
        lockProvider.overrideWithValue(lock),
        authServiceProvider.overrideWithValue(auth),
        supabaseProvider.overrideWithValue(client),
        messengerProvider.overrideWithValue(repository),
      ], child: MaterialApp(home: PrivacyGate(lock: lock,
        authenticated: () => auth.signedIn && auth.deviceAuthorized && auth.ownerMatches,
        authChanges: auth, child: screen))));
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(StatusScreen));
      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New ${outcome == 'video' ? 'video' : 'image'} update'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(pickerCalls, 1);
      expect(lock.mediaPickerActive, isTrue);
      expect(find.text('No updates right now. Share a moment.'), findsNothing);
      expect(find.byType(StatusScreen, skipOffstage: false), findsOneWidget);
      for (final lifecycle in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        lock.didChangeAppLifecycleState(lifecycle);
      }
      if (outcome == 'Home') native.leave();
      if (outcome == 'manual lock') lock.lock();
      if (outcome == 'revoked device') { auth.deviceAuthorized = false; lock.lock(); }
      if (outcome == 'expired session') { auth.active = false; lock.lock(); }
      if (outcome == 'repeated launch') {
        await expectLater(lock.pickMedia('video', () async => null,
          authorized: () => true, reauthorize: () async => true), throwsStateError);
        expect(pickerCalls, 1);
      }
      lock.didChangeAppLifecycleState(AppLifecycleState.resumed);
      // File/Storage SDK work can use real asynchronous I/O. Do not advance
      // the fake two-minute lock timer while waiting for those operations.
      await tester.runAsync(() async {
        selected.complete(outcome == 'cancel' ? null : outcome == 'missing file'
            ? MissingMediaFile()
            : XFile.fromData(Uint8List.fromList([1, 2, 3]), path: outcome == 'video' ? '/fixture.mp4' : '/fixture.jpg'));
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (state.mounted && (state as dynamic).posting == true) {
          if (DateTime.now().isAfter(deadline)) fail('Picker operation did not finish: $requests');
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      });
      await tester.pumpAndSettle();
      final posts = requests.where((path) => path.endsWith('/rpc/create_status'));
      final expectedPost = ['image', 'video', 'repeated launch'].contains(outcome);
      expect(posts.length, expectedPost ? 1 : 0, reason: 'Requests: $requests; visible text: ${tester.widgetList<Text>(find.byType(Text)).map((widget) => widget.data).toList()}');
      if (expectedPost) {
        expect(requests.any((path) => path.endsWith('/functions/v1/validate-media')), isTrue);
        expect(requests.any((path) => path.contains('/storage/v1/object/status-media/')), isTrue);
      }
      if (['Home', 'manual lock', 'revoked device', 'expired session'].contains(outcome)) {
        expect(lock.unlocked, isFalse);
        expect(find.text('No updates right now. Share a moment.'), findsNothing);
      } else {
        expect(lock.unlocked, isTrue);
        expect(tester.state(find.byType(StatusScreen)), same(state));
        expect(find.text('No updates right now. Share a moment.'), findsOneWidget);
        expect(auth.rechecks, greaterThan(0));
      }
      await tester.pumpWidget(const SizedBox.shrink());
      auth.dispose();
      lock.dispose();
      await tester.runAsync(() async {
        await repository.dispose();
        await client.dispose();
      });
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
}
