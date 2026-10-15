import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../security/lock_controller.dart';
import '../security/pin_vault.dart';

class AuthService extends ChangeNotifier {
  AuthService(this.client, this.lock, this.store) {
    _sessionUser = client?.auth.currentUser?.id;
    _subscription = client?.auth.onAuthStateChange.listen((event) {
      final nextUser = event.session?.user.id;
      if (nextUser != _sessionUser) {
        _sessionUser = nextUser;
        ownerMatches = false;
        _freshUser = null;
        lock.lock();
        unawaited(_refreshOwner(nextUser));
      }
      if (event.event == AuthChangeEvent.signedOut) {
        lock.lock();
        _freshUser = null;
      }
      if (event.event == AuthChangeEvent.passwordRecovery) {
        recovery = true;
        lock.lock();
      }
      notifyListeners();
    });
  }
  final SupabaseClient? client;
  final LockController lock;
  final SecretStore store;
  StreamSubscription<AuthState>? _subscription;
  String? _freshUser;
  String? _sessionUser;
  Future<void> _refreshOwner(String? uid) async {
    final owner = await store.read('pin.owner');
    if (_sessionUser == uid) {
      ownerMatches = uid != null && owner == uid;
      notifyListeners();
    }
  }

  DateTime? _freshAt;
  bool recovery = false;
  bool ownerMatches = false;
  Future<void> initialize() async {
    ownerMatches =
        await store.read('pin.owner') == client?.auth.currentUser?.id &&
        signedIn;
  }

  bool get signedIn => client?.auth.currentUser != null;
  bool get recentlyAuthenticated =>
      signedIn &&
      _freshUser == client!.auth.currentUser!.id &&
      _freshAt != null &&
      DateTime.now().difference(_freshAt!) < const Duration(minutes: 5);
  Future<void> signIn(String email, String password) async {
    if (client == null) throw StateError('Configure Supabase first');
    lock.lock();
    final response = await client!.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
    _freshUser = response.user?.id;
    _freshAt = DateTime.now();
    final owner = await store.read('pin.owner');
    if (owner != response.user?.id && lock.hasPin) {
      await lock.vault.clear();
      lock.hasPin = false;
    }
    ownerMatches = owner == response.user?.id;
    notifyListeners();
  }

  Future<void> configurePin(String pin) async {
    if (!recentlyAuthenticated) {
      throw StateError('Sign in again before setting a PIN');
    }
    await lock.vault.configure(pin);
    await store.write('pin.owner', client!.auth.currentUser!.id);
    lock.hasPin = true;
    ownerMatches = true;
    await lock.initialize();
    lock.lock();
    notifyListeners();
  }

  Future<void> signOut() async {
    lock.lock();
    _freshUser = null;
    await client?.auth.signOut();
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
