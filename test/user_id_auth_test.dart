import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:calculator_messenger/core/security/lock_controller.dart';
import 'package:calculator_messenger/core/security/pin_vault.dart';
import 'package:calculator_messenger/core/services/account_input.dart';
import 'package:calculator_messenger/core/services/auth_service.dart';
import 'package:calculator_messenger/features/authentication/auth_screen.dart';
import 'pin_vault_test.dart' show MemorySecrets;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const owner = '12000000-0000-0000-0000-000000000001';
  const session = '12000000-0000-0000-0000-000000000002';
  const password = 'a-long-fixture-password';
  late SupabaseClient client;
  late AuthService auth;
  late LockController lock;
  late MemorySecrets secrets;
  final requests = <Map<String, dynamic>>[];
  bool allowed = true;
  bool duplicate = false;
  bool badCredentials = false;
  String encode(Object value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  setUp(() {
    requests.clear(); allowed = true; duplicate = false; badCredentials = false;
    secrets = MemorySecrets();
    lock = LockController(PinVault(secrets, iterations: 1000));
    client = SupabaseClient('https://fixture.invalid', 'public-fixture-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        http.Response json(Object data, [int status = 200]) => http.Response(jsonEncode(data), status,
          headers: {'content-type': 'application/json'}, request: request);
        if (request.url.path.endsWith('/functions/v1/account-auth')) {
          final input = jsonDecode(request.body) as Map<String, dynamic>;
          requests.add(input);
          if (duplicate) return json({'code': 'user_id_unavailable'}, 409);
          if (badCredentials) return json({'code': 'invalid_credentials'}, 401);
          return json({
            'refresh_token': 'fixture-refresh', 'user_uuid': owner,
            if (input['action'] != 'login') 'recovery_codes': List.generate(8, (i) => i.toRadixString(16).padLeft(64, '0')),
          });
        }
        if (request.url.path.endsWith('/auth/v1/token')) {
          final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          return json({
            'access_token': '${encode({'alg': 'HS256'})}.${encode({'sub': owner, 'session_id': session, 'iat': now, 'exp': now + 3600})}.fixture',
            'refresh_token': 'fixture-refresh', 'expires_in': 3600, 'token_type': 'bearer',
            'user': {'id': owner, 'aud': 'authenticated', 'created_at': '2026-01-01T00:00:00Z', 'app_metadata': {}, 'user_metadata': {}},
          });
        }
        if (request.url.path.endsWith('/rpc/device_access_status')) return json({'authorized': allowed, 'enforced': true, 'session_id': session});
        if (request.url.path.endsWith('/auth/v1/logout')) return json({});
        if (request.url.path.endsWith('/functions/v1/device-security')) return json({'reauthenticated': true});
        throw StateError('Unexpected fixture request: ${request.url.path}');
      }));
    auth = AuthService(client, lock, secrets);
  });
  tearDown(() async { auth.dispose(); lock.dispose(); await client.dispose(); });

  test('manual User ID and display name validation; matching strong passwords', () {
    expect(AccountInput.userId('chosen_id'), 'chosen_id');
    expect(AccountInput.username(' Name '), 'Name');
    for (final id in ['ab', 'Upper', 'name@domain.com', 'space name']) {
      expect(() => AccountInput.userId(id), throwsFormatException);
    }
    expect(() => AccountInput.password('short', 'short'), throwsFormatException);
    expect(() => AccountInput.password(password, 'different'), throwsFormatException);
    expect(() => AccountInput.username(' '), throwsFormatException);
  });
  test('mismatch and weak password never reach server', () async {
    await expectLater(auth.signUp('chosen_id', 'Name', password, 'different'), throwsFormatException);
    await expectLater(auth.signUp('chosen_id', 'Name', 'short', 'short'), throwsFormatException);
    expect(requests, isEmpty);
  });
  test('signup authenticates immediately but requires device/PIN and code acknowledgment', () async {
    await auth.signUp('chosen_id', 'Chosen name', password, password);
    expect(auth.signedIn, isTrue);
    expect(auth.recentlyAuthenticated, isTrue);
    expect(lock.unlocked, isFalse);
    expect(auth.recoveryCodes.length, 8);
    expect(auth.nextSecurityRoute, '/recovery-codes');
    expect(requests.single['user_id'], 'chosen_id');
    expect(requests.single['username'], 'Chosen name');
    expect(requests.single.containsKey('email'), isFalse);
    auth.acknowledgeRecoveryCodes();
    expect(auth.nextSecurityRoute, '/pin');
    await auth.configurePin('462819', openMessenger: true);
    expect(lock.unlocked && auth.ownerMatches && auth.deviceAuthorized, isTrue);
    expect(await secrets.read('pin.owner'), owner);
    expect(secrets.values.values.any((value) => value.contains(password)), isFalse);
    expect(secrets.values.keys.any((key) => key.contains('recovery')), isFalse);
  });
  test('duplicate ID and invalid credentials become safe messages', () async {
    duplicate = true;
    await expectLater(auth.signUp('chosen_id', 'Name', password, password),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', 'This User ID is unavailable.')));
    duplicate = false; badCredentials = true;
    await expectLater(auth.signIn('chosen_id', 'wrong'),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', 'User ID or password is incorrect.')));
    expect(auth.signedIn, isFalse);
  });
  test('logout/login retains owner-bound PIN, never silently unlocks it', () async {
    await auth.signIn('chosen_id', password);
    await auth.configurePin('462819');
    await auth.signOut();
    await auth.signIn('chosen_id', password);
    expect(auth.ownerMatches, isTrue);
    expect(lock.hasPin, isTrue);
    expect(lock.unlocked, isFalse);
    expect(requests.last['user_id'], 'chosen_id');
  });
  test('unapproved device cannot configure or automatically unlock PIN', () async {
    allowed = false;
    await auth.signIn('chosen_id', password);
    expect(auth.nextSecurityRoute, '/devices');
    await expectLater(auth.configurePin('462819', openMessenger: true), throwsStateError);
    expect(lock.unlocked, isFalse);
  });
  testWidgets('registration exposes User ID, Username and confirmation; no email field', (tester) async {
    await tester.pumpWidget(MaterialApp(home: AuthScreen(auth: auth)));
    await tester.tap(find.text('Create an account'));
    await tester.pump();
    expect(find.text('User ID'), findsOneWidget);
    expect(find.text('Username'), findsOneWidget);
    expect(find.text('Retype password'), findsOneWidget);
    expect(find.text('Email'), findsNothing);
    expect(find.textContaining('verify your account'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
