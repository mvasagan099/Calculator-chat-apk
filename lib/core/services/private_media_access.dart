import 'package:supabase_flutter/supabase_flutter.dart';
import '../security/lock_controller.dart';
import 'auth_service.dart';

/// Captured once per UI operation. No callback may act for a different account,
/// session, device approval, or unlock epoch, including after another unlock.
class PrivateMediaAccess {
  PrivateMediaAccess(this.lock, this.auth, this.client, {this.isCurrent})
      : _epoch = lock.securityEpoch,
        _owner = client.auth.currentUser?.id,
        _session = AuthService.tokenSession(client.auth.currentSession);
  final LockController lock;
  final AuthService? auth;
  final SupabaseClient client;
  final bool Function()? isCurrent;
  final int _epoch;
  final String? _owner, _session;
  bool get authorized => (isCurrent?.call() ?? true) && auth != null && auth!.signedIn && auth!.ownerMatches &&
      auth!.deviceAuthorized && _owner != null && _session != null &&
      client.auth.currentUser?.id == _owner &&
      AuthService.tokenSession(client.auth.currentSession) == _session;
  bool get valid => authorized && lock.privateActionValid(_epoch);
  void check() {
    if (!valid) throw StateError('Media operation cancelled. Unlock your approved session and try again.');
  }
  Future<T?> pick<T>(String kind, Future<T?> Function() request) async {
    check();
    return lock.pickMedia(kind, request, authorized: () => authorized,
      reauthorize: () async {
        await auth!.refreshDeviceAccess();
        return authorized;
      });
  }
}
