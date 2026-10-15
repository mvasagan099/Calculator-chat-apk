import 'package:supabase_flutter/supabase_flutter.dart';
import 'pin_vault.dart';

class SecureSessionStorage extends LocalStorage {
  SecureSessionStorage(this.store);
  final SecretStore store;
  static const key = 'supabase.session.v1';
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> hasAccessToken() async => await store.read(key) != null;
  @override
  Future<String?> accessToken() => store.read(key);
  @override
  Future<void> persistSession(String persistSessionString) =>
      store.write(key, persistSessionString);
  @override
  Future<void> removePersistedSession() => store.delete(key);
}
