import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:calculator_messenger/core/router/app_router.dart';
import 'package:calculator_messenger/core/security/lock_controller.dart';
import 'package:calculator_messenger/core/services/device_settings.dart';
import 'package:calculator_messenger/features/chats/message_yourself_tile.dart';
import 'package:calculator_messenger/features/chats/chat_list_screen.dart';
import 'package:calculator_messenger/repositories/messenger_repository.dart';
import 'package:calculator_messenger/features/contacts/contacts_screen.dart';
import 'package:calculator_messenger/features/notifications/app_update.dart';
import 'package:calculator_messenger/features/notifications/notification_activity.dart';
import 'package:calculator_messenger/features/notifications/notification_service.dart';
import 'package:calculator_messenger/providers/app_providers.dart';
import 'lock_biometric_test.dart' show ImmediatePinVault;
import 'status_picker_test.dart' show PickerFixtureAuth;

class RecordingNotifications implements FlutterLocalNotificationsPlugin {
  final shown = <Map<String, dynamic>>[];
  @override
  Future<void> show({required int id, String? title, String? body,
    NotificationDetails? notificationDetails, String? payload}) async {
    shown.add({'id': id, 'title': title, 'body': body, 'details': notificationDetails, 'payload': payload});
  }
  @override
  Future<void> cancelAll() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('Unexpected notification operation');
}

class EmptyConversationFixture extends MessengerRepository {
  EmptyConversationFixture(super.client);
  @override
  Stream<List<Map<String, dynamic>>> conversations() => Stream.value([]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const owner = '15000000-0000-0000-0000-000000000001';
  const sid = '15000000-0000-0000-0000-000000000002';
  const cid = '15000000-0000-0000-0000-000000000003';
  const mid = '15000000-0000-0000-0000-000000000004';
  final installed = <String, dynamic>{'package_id': 'app.calculatorspace.calculator_messenger', 'build_number': 1, 'abi': 'arm64-v8a',
    'certificate_sha256': List.filled(64, 'A').join()};
  Map<String, dynamic> release() => {'id': mid, 'build_number': 2, 'package_id': installed['package_id'], 'abi': installed['abi'],
    'certificate_sha256': installed['certificate_sha256'], 'apk_sha256': List.filled(64, 'b').join(),
    'apk_url': 'https://github.com/mvasagan099/Calculator-chat-apk/releases/download/v2/app-arm64.apk',
    'published': true, 'published_at': '2026-01-01T00:00:00Z'};
  late SupabaseClient client;
  late LockController lock;
  late PickerFixtureAuth auth;
  late NotificationService notifications;
  late RecordingNotifications local;
  dynamic target, manifest;
  Completer<dynamic>? deferredTarget, deferredCreate;
  var deny = false;
  final requests = <({String path, String body})>[];
  String encoded(Object value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  setUp(() async {
    requests.clear(); deny = false; deferredTarget = null; deferredCreate = null;
    target = {'conversation_id': cid}; manifest = null;
    SharedPreferences.setMockInitialValues({});
    client = SupabaseClient('https://fixture.invalid', 'public-fixture',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        requests.add((path: request.url.path, body: request.body));
        dynamic body = {};
        var status = 200;
        if (request.url.path.endsWith('/auth/v1/token')) {
          final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          body = {'access_token': '${encoded({'alg': 'HS256'})}.${encoded({'sub': owner, 'session_id': sid, 'iat': now, 'exp': now + 3600})}.fixture',
            'refresh_token': 'fixture-refresh', 'expires_in': 3600, 'token_type': 'bearer',
            'user': {'id': owner, 'aud': 'authenticated', 'created_at': '2026-01-01T00:00:00Z', 'app_metadata': {}, 'user_metadata': {}}};
        } else if (request.url.path.endsWith('/rpc/notification_message_target')) {
          body = deferredTarget == null ? target : await deferredTarget!.future;
          if (deny) { status = 403; body = {'message': 'Not authorized', 'code': '42501'}; }
        } else if (request.url.path.endsWith('/rpc/create_direct')) {
          body = deferredCreate == null ? cid : await deferredCreate!.future;
        } else if (request.url.path.endsWith('/rpc/latest_android_release')) {
          body = manifest;
        } else if (request.url.path.endsWith('/user_settings')) {
          body = {'notifications': true};
        }
        return http.Response(jsonEncode(body), status, request: request, headers: {'content-type': 'application/json'});
      }));
    await client.auth.setSession('fixture-refresh');
    lock = LockController(ImmediatePinVault())..hasPin = true;
    auth = PickerFixtureAuth(client, lock);
    local = RecordingNotifications();
    notifications = NotificationService(local: local)..bindClient(client);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('calculator_messenger/privacy'), (call) async => installed);
  });
  tearDown(() async {
    notifications.dispose(); auth.dispose(); lock.dispose(); await client.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('calculator_messenger/privacy'), null);
  });
  RemoteMessage incoming() => const RemoteMessage(messageId: 'provider-delivery', data: {
    'kind': 'message', 'resource_id': mid, 'recipient_id': owner,
    'sender': 'Private sender', 'body': 'Secret text', 'filename': 'secret.pdf', 'version': '999'});

  test('foreground message content is generic and repeated deliveries are suppressed', () async {
    await Future.wait([notifications.handleForeground(incoming()), notifications.handleForeground(incoming())]);
    await notifications.handleForeground(incoming());
    expect(local.shown.length, 1);
    final item = local.shown.single;
    expect(item['title'], 'Calculator'); expect(item['body'], 'New update arrived');
    final android = (item['details'] as NotificationDetails).android!;
    expect(android.tag, 'message:$mid'); expect(android.icon, 'ic_notification'); expect(item['id'], 0);
    expect(item['payload'], isNot(contains('Secret')));
    expect(item['payload'], isNot(contains('Private sender')));
    expect(lock.unlocked, isFalse); // Generic delivery must not unlock the app.
  });
  for (final reason in ['self/sender', 'muted', 'blocked', 'expired', 'deleted', 'disabled', 'non-member']) {
    test('foreground rejects $reason when the guarded backend returns no target', () async {
      target = null;
      await notifications.handleForeground(incoming());
      expect(local.shown, isEmpty);
      expect(requests.any((r) => r.path.endsWith('/rpc/notification_message_target')), isTrue);
    });
  }
  test('revoked/unauthorized lookup and wrong recipient never display a message', () async {
    deny = true; await notifications.handleForeground(incoming());
    await notifications.handleForeground(const RemoteMessage(data: {'kind': 'message', 'resource_id': mid, 'recipient_id': cid}));
    expect(local.shown, isEmpty);
  });
  test('real version notice requires matching installed identity and higher published build', () async {
    await notifications.checkForAppUpdate(); expect(local.shown, isEmpty);
    manifest = release(); await notifications.checkForAppUpdate();
    expect(local.shown.single['body'], 'Update to the latest version');
    await notifications.checkForAppUpdate(); expect(local.shown.length, 1);
  });
  test('version validator rejects older, unpublished, foreign, future and malformed releases', () {
    final valid = release(); expect(VerifiedAppUpdate.parse(installed, valid), isNotNull);
    for (final change in [
      {'build_number': 1}, {'build_number': 0}, {'published': false}, {'package_id': 'foreign'}, {'abi': 'armeabi-v7a'},
      {'certificate_sha256': List.filled(64, 'C').join()}, {'published_at': '2999-01-01T00:00:00Z'},
      {'apk_url': 'https://evil.invalid/app.apk'}, {'apk_url': '${valid['apk_url']}?redirect=bad'},
      {'apk_sha256': 'invalid'}, {'id': '../private'},
    ]) { expect(VerifiedAppUpdate.parse(installed, {...valid, ...change}), isNull); }
  });
  test('notification parser drops preview data, rejects recipient forgery and ignores message version text', () {
    expect(NotificationActivity.parse(incoming().data), {'kind': 'message', 'resource_id': mid, 'recipient_id': owner});
    expect(NotificationActivity.parse({'kind': 'message', 'resource_id': mid, 'recipient_id': '/private'}), isNull);
    expect(NotificationActivity.body(incoming().data), 'New update arrived');
  });

  testWidgets('Message Yourself opens one self RPC, not a contact action', (tester) async {
    await lock.unlock('2580');
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const Scaffold(body: MessageYourselfTile())),
      GoRoute(path: '/chat/:id', builder: (_, _) => const Text('Self conversation opened')),
    ]);
    await tester.pumpWidget(ProviderScope(overrides: [lockProvider.overrideWithValue(lock),
      authServiceProvider.overrideWithValue(auth), supabaseProvider.overrideWithValue(client)],
      child: MaterialApp.router(routerConfig: router)));
    await tester.tap(find.text('Message Yourself'));
    await tester.pumpAndSettle();
    final calls = requests.where((r) => r.path.endsWith('/rpc/create_direct')).toList();
    expect(calls.length, 1); expect(jsonDecode(calls.single.body), {'peer': owner});
    expect(requests.any((r) => r.path.endsWith('/contacts')), isFalse);
    expect(find.text('Self conversation opened'), findsOneWidget);
    lock.lock();
    await tester.pumpWidget(const SizedBox.shrink()); router.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
  testWidgets('chat list offers Message Yourself even with no conversations', (tester) async {
    final repository = EmptyConversationFixture(client);
    await tester.pumpWidget(ProviderScope(overrides: [messengerProvider.overrideWithValue(repository)],
      child: const MaterialApp(home: ChatListScreen())));
    await tester.pumpAndSettle();
    expect(find.text('Message Yourself'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink()); await repository.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
  for (final selection in [false, true]) {
    testWidgets('New Chat self option is present only outside contact selection=$selection', (tester) async {
      await tester.pumpWidget(ProviderScope(overrides: [supabaseProvider.overrideWithValue(client)],
        child: MaterialApp(home: ContactsScreen(selectOnly: selection))));
      expect(find.text('Message Yourself'), selection ? findsNothing : findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
  testWidgets('stale self creation cannot navigate after manual locking', (tester) async {
    await lock.unlock('2580'); deferredCreate = Completer<dynamic>();
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const Scaffold(body: MessageYourselfTile())),
      GoRoute(path: '/chat/:id', builder: (_, _) => const Text('Private self chat')),
    ]);
    await tester.pumpWidget(ProviderScope(overrides: [lockProvider.overrideWithValue(lock),
      authServiceProvider.overrideWithValue(auth), supabaseProvider.overrideWithValue(client)],
      child: MaterialApp.router(routerConfig: router)));
    await tester.tap(find.text('Message Yourself')); await tester.pump();
    lock.lock(); deferredCreate!.complete(cid); await tester.pumpAndSettle();
    expect(find.text('Private self chat'), findsNothing);
    lock.lock();
    await tester.pumpWidget(const SizedBox.shrink()); router.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
  for (final outcome in ['valid', 'locked', 'stale', 'missing', 'recipient mismatch', 'device revoked']) {
    testWidgets('notification routing remains gated: $outcome', (tester) async {
      final device = DeviceSettings(await SharedPreferences.getInstance(), lock);
      final routing = AppRouter(auth, device, notifications);
      notifications.pending = {'kind': 'message', 'resource_id': mid, 'recipient_id': outcome == 'recipient mismatch' ? cid : owner};
      if (outcome == 'missing') target = null;
      if (outcome != 'locked') await lock.unlock('2580');
      if (outcome == 'stale') {
        // Set a new pending item after the automatic unlock listener settles.
        await tester.pump();
        routing.router.go('/'); deferredTarget = Completer<dynamic>();
        notifications.pending = {'kind': 'message', 'resource_id': mid, 'recipient_id': owner};
        final opening = routing.openPending(); await tester.pump();
        lock.lock(); await lock.unlock('2580'); deferredTarget!.complete({'conversation_id': cid});
        await opening;
      } else {
        if (outcome == 'device revoked') { auth.deviceAuthorized = false; lock.lock(); }
        await routing.openPending(); await tester.pump();
      }
      expect(routing.router.routeInformationProvider.value.uri.path, outcome == 'valid' ? '/chat/$cid' : '/');
      routing.dispose(); device.dispose();
      lock.lock(); // Cancel the fixture timer before binding invariant checks.
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
}
