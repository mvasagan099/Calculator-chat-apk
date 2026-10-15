import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:calculator_messenger/core/security/pin_vault.dart';
import 'package:calculator_messenger/core/security/lock_controller.dart';
import 'package:calculator_messenger/core/services/auth_service.dart';
import 'pin_vault_test.dart' show MemorySecrets;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SupabaseClient client;
  late AuthService auth;
  late LockController lock;
  bool allowed = false, offline = false;
  setUp(() async {
    allowed = false;
    offline = false;
    client = SupabaseClient(
      'https://example.invalid',
      'public-test-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        if (offline) throw http.ClientException('offline');
        if (request.url.path.endsWith('/rpc/device_access_status')) {
          return http.Response(
            jsonEncode({
              'authorized': allowed,
              'enforced': true,
              'session_id': '71000000-0000-0000-0000-000000000001',
              'device': {'id': 'pending', 'link_code': 'fixture-code'},
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        throw StateError('Unexpected request ${request.url.path}');
      }),
    );
    String encode(Object value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final token =
        '${encode({'alg': 'HS256'})}.${encode({'sub': 'owner', 'session_id': '71000000-0000-0000-0000-000000000001', 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600})}.test';
    await client.auth.recoverSession(
      jsonEncode({
        'access_token': token,
        'refresh_token': 'fixture',
        'token_type': 'bearer',
        'user': {
          'id': 'owner',
          'app_metadata': {},
          'user_metadata': {},
          'aud': 'authenticated',
          'created_at': '2026-01-01T00:00:00Z',
        },
      }),
    );
    final secrets = MemorySecrets();
    await secrets.write('pin.owner', 'owner');
    lock = LockController(PinVault(secrets, iterations: 1000));
    await lock.vault.configure('462819');
    await lock.initialize();
    auth = AuthService(client, lock, secrets);
  });
  tearDown(() async {
    auth.dispose();
    lock.dispose();
    await client.dispose();
  });
  test(
    'HTTP adapter: approval is an independent gate, with no auto-unlock',
    () async {
      await auth.initialize();
      expect(auth.signedIn && auth.ownerMatches, isTrue);
      expect(auth.deviceAuthorized, isFalse);
      allowed = true;
      await auth.refreshDeviceAccess(initial: true);
      expect(auth.deviceAuthorized, isTrue);
      expect(lock.unlocked, isFalse);
    },
  );
  test(
    'HTTP adapter: revocation locks an already unlocked calculator session',
    () async {
      allowed = true;
      await auth.initialize();
      await lock.unlock('462819');
      expect(lock.unlocked, isTrue);
      allowed = false;
      await auth.refreshDeviceAccess();
      expect(lock.unlocked, isFalse);
      expect(auth.deviceAuthorized, isFalse);
    },
  );
  test(
    'HTTP adapter: unavailable initial authorization fails closed; an existing approved session tolerates temporary loss',
    () async {
      offline = true;
      await auth.initialize();
      expect(auth.deviceAuthorized, isFalse);
      offline = false;
      allowed = true;
      await auth.refreshDeviceAccess(initial: true);
      await lock.unlock('462819');
      offline = true;
      await auth.refreshDeviceAccess();
      expect(auth.deviceAuthorized, isTrue);
      expect(lock.unlocked, isTrue);
    },
  );
}
