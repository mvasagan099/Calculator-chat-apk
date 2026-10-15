import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';
import '../security/pin_vault.dart';

class DeviceAccessService {
  DeviceAccessService(this.client, this.store);
  final SupabaseClient client;
  final SecretStore store;
  final _identities = <String, Future<String>>{};
  Future<String> identity() {
    final owner = client.auth.currentUser?.id;
    if (owner == null) throw StateError('Sign in first');
    return _identities.putIfAbsent(owner, () => _identity(owner));
  }

  Future<String> _identity(String owner) async {
    final key = 'device.id.$owner';
    final existing = await store.read(key);
    if (existing != null) return existing;
    final value = const Uuid().v4();
    await store.write(key, value);
    return value;
  }

  Future<Map<String, dynamic>> status() async =>
      Map<String, dynamic>.from(await client.rpc('device_access_status'));
  Future<Map<String, dynamic>> request() async => Map<String, dynamic>.from(
    await client.rpc(
      'request_device_approval',
      params: {'device': await identity(), 'device_name': 'Android device'},
    ),
  );
  Future<void> revokeCurrent() async {
    final token = client.auth.currentSession?.accessToken;
    if (token == null || !AppConfig.configured) return;
    // Capture the authorization before local sign-out; never retain it on disk.
    final response = await http
        .post(
          Uri.parse('${AppConfig.supabaseUrl}/rest/v1/rpc/revoke_this_device'),
          headers: {
            'apikey': AppConfig.supabaseKey,
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: '{}',
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Session revocation pending');
    }
  }

  Future<void> manage(
    String action,
    String password, {
    String? target,
    String? code,
    String? name,
  }) async {
    final response = await client.functions.invoke(
      'device-security',
      body: {
        'action': action,
        'password': password,
        'target': target,
        'code': code,
        if (action == 'enable') 'device_id': await identity(),
        if (action == 'enable') 'name': name ?? 'Android device',
      },
    );
    if (response.status != 200 ||
        (action == 'reauthenticate' &&
            response.data['reauthenticated'] != true)) {
      throw StateError('Device security update failed');
    }
  }
}
