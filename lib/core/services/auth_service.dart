import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../security/lock_controller.dart';
import '../security/pin_vault.dart';
import 'device_access_service.dart';
import 'account_input.dart';
import 'account_gateway.dart';
import '../config/app_config.dart';

class AuthService extends ChangeNotifier {
  AuthService(this.client, this.lock, this.store) {
    _sessionUser = client?.auth.currentUser?.id;
    _tokenSession = tokenSession(client?.auth.currentSession);
    scheduleExpiry();
    _subscription = client?.auth.onAuthStateChange.listen((event) {
      final nextUser = event.session?.user.id;
      final nextSession = tokenSession(event.session);
      if (nextSession != _tokenSession || nextUser != _sessionUser) {
        _tokenSession = nextSession;
        ++_accessGeneration;
        deviceAuthorized = false;
        lock.lock();
      }
      scheduleExpiry();
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
        recoveryCodes = const [];
      }
      if (event.event == AuthChangeEvent.passwordRecovery) {
        // Legacy provider links never authorize PIN replacement in this UI.
        _freshUser = null;
        lock.lock();
      }
      if (nextUser != null) {
        _subscribeDeviceRealtime(nextUser);
        unawaited(refreshDeviceAccess());
      } else {
        _unsubscribeDeviceRealtime();
      }
      if (!_disposed) notifyListeners();
    });
  }
  final SupabaseClient? client;
  final LockController lock;
  final SecretStore store;
  StreamSubscription<AuthState>? _subscription;
  RealtimeChannel? _deviceChannel;
  String? _freshUser;
  String? _sessionUser;

  void _subscribeDeviceRealtime(String uid) {
    _unsubscribeDeviceRealtime();
    final c = client;
    if (c == null) return;
    try {
      final ch = c.channel('devices-$uid-${const Uuid().v4()}');
      _deviceChannel = ch;
      ch.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'account_devices',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'user_id',
          value: uid,
        ),
        callback: (_) {
          if (!_disposed) unawaited(refreshDeviceAccess());
        },
      ).subscribe();
    } catch (_) {}
  }

  void _unsubscribeDeviceRealtime() {
    final ch = _deviceChannel;
    _deviceChannel = null;
    if (ch != null && client != null) {
      unawaited(client!.removeChannel(ch));
    }
  }

  Future<void> _refreshOwner(String? uid) async {
    final owner = await store.read('pin.owner');
    if (_sessionUser == uid) {
      ownerMatches = uid != null && owner == uid;
      if (!_disposed) notifyListeners();
    }
  }

  DateTime? _freshAt;
  static String? tokenSession(Session? session) {
    if (session == null) return null;
    try {
      return (jsonDecode(
                utf8.decode(
                  base64Url.decode(
                    base64Url.normalize(session.accessToken.split('.')[1]),
                  ),
                ),
              )
              as Map<String, dynamic>)['session_id']
          as String?;
    } catch (_) {
      return null;
    }
  }

  String? _tokenSession;
  Timer? _expiry;
  int _accessGeneration = 0;
  void scheduleExpiry() {
    _expiry?.cancel();
    final seconds = client?.auth.currentSession?.expiresAt;
    if (seconds == null) return;
    final remaining = DateTime.fromMillisecondsSinceEpoch(
      seconds * 1000,
    ).difference(DateTime.now());
    _expiry = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      if (!_disposed && client?.auth.currentSession?.isExpired != false) {
        deviceAuthorized = false;
        lock.lock();
        notifyListeners();
      }
    });
  }

  bool _disposed = false;
  bool deviceAuthorized = false;
  Map<String, dynamic>? deviceStatus;
  DeviceAccessService? _deviceAccess;
  DeviceAccessService get deviceAccess =>
      _deviceAccess ??= DeviceAccessService(client!, store);
  Future<void> refreshDeviceAccess({bool initial = false}) async {
    final generation = ++_accessGeneration;
    final owner = client?.auth.currentUser?.id;
    if (owner == null) {
      deviceAuthorized = false;
      return;
    }
    final token = client!.auth.currentSession?.accessToken;
    try {
      var status = await deviceAccess.status();
      final pending = status['device'] as Map<String, dynamic>?;
      final expires = DateTime.tryParse(pending?['request_expires_at'] ?? '');
      if (status['enforced'] == true &&
          status['authorized'] != true &&
          (pending == null ||
              (pending['revoked_at'] == null &&
                  pending['approved_at'] == null &&
                  expires != null &&
                  !expires.isAfter(DateTime.now())))) {
        status = await deviceAccess.request();
      }
      if (_disposed ||
          generation != _accessGeneration ||
          client?.auth.currentUser?.id != owner ||
          token != client?.auth.currentSession?.accessToken) {
        return;
      }
      deviceStatus = status;
      final wasAuthorized = deviceAuthorized;
      deviceAuthorized = status['authorized'] == true;
      if (!deviceAuthorized || !wasAuthorized) lock.lock();
    } catch (_) {
      if (_disposed || generation != _accessGeneration) return;
      if (initial || client?.auth.currentSession?.isExpired != false) {
        deviceAuthorized = false;
        lock.lock();
      }
    }
    if (!_disposed) notifyListeners();
  }

  bool ownerMatches = false;
  Future<void> initialize() async {
    ownerMatches =
        await store.read('pin.owner') == client?.auth.currentUser?.id &&
        signedIn;
    if (signedIn) await refreshDeviceAccess(initial: true);
  }

  bool get signedIn =>
      client?.auth.currentUser != null &&
      client?.auth.currentSession?.isExpired == false;
  bool get recentlyAuthenticated =>
      signedIn &&
      _freshUser == client!.auth.currentUser!.id &&
      _freshAt != null &&
      DateTime.now().difference(_freshAt!) < const Duration(minutes: 5);
  List<String> recoveryCodes = const [];
  AccountGateway? _accountGateway;
  bool _accountBusy = false;
  int _loginGeneration = 0;
  String get nextSecurityRoute => !deviceAuthorized
      ? '/devices'
      : recoveryCodes.isNotEmpty
      ? '/recovery-codes'
      : !lock.hasPin || !ownerMatches
      ? '/pin'
      : '/';

  Future<Map<String, dynamic>> _accountRequest(Map<String, dynamic> input) async {
    if (client == null) throw StateError('Configure Supabase first');
    if (AppConfig.accountAuthGatewayUrl.isNotEmpty) {
      return (_accountGateway ??= AccountGateway(AppConfig.accountAuthGatewayUrl))
          .invoke(input, accessToken: client!.auth.currentSession?.accessToken);
    }
    // Legacy fixture path. Production connected configuration now requires a
    // gateway URL; direct public Supabase invocation fails closed.
    try {
      final response = await client!.functions.invoke('account-auth', body: input);
      if (response.status != 200 || response.data is! Map) {
        throw const FormatException('Account operation unavailable.');
      }
      return Map<String, dynamic>.from(response.data as Map);
    } on FunctionException catch (error) {
      final details = error.details;
      // Only render adapter-authored, allowlisted codes; never raw provider errors.
      final code = details is Map ? details['code'] : null;
      throw FormatException(switch (code) {
        'user_id_unavailable' => 'This username is unavailable.',
        'invalid_credentials' => 'Username or password is incorrect.',
        'invalid_recovery' => 'Username or recovery code is invalid or already used.',
        'rate_limited' => 'Too many attempts. Try again later.',
        'account_created' => 'Account created. Sign in, then save recovery codes in Settings.',
        _ => 'Account operation unavailable. Check your connection and try again.',
      });
    }
  }

  Future<void> _authenticateAccount(
    Map<String, dynamic> input, {
    String? recoveredDevice,
  }) async {
    if (_accountBusy) throw StateError('A sign-in is already in progress');
    _accountBusy = true;
    final generation = ++_loginGeneration;
    lock.lock();
    recoveryCodes = const [];
    try {
      final data = await _accountRequest(input);
      if (_disposed || generation != _loginGeneration) throw StateError('Sign-in cancelled');
      final token = data['refresh_token'];
      final expectedOwner = data['user_uuid'];
      if (token is! String || expectedOwner is! String ||
          !RegExp(r'^[0-9a-f-]{36}$').hasMatch(expectedOwner)) {
        throw StateError('Invalid account response');
      }
      final response = await client!.auth.setSession(token);
      if (_disposed || generation != _loginGeneration || response.user?.id != expectedOwner) {
        await client!.auth.signOut(scope: SignOutScope.local);
        throw StateError('Sign-in cancelled');
      }
      if (recoveredDevice != null) {
        await store.write('device.id.$expectedOwner', recoveredDevice);
      }
      _freshUser = response.user?.id;
      _freshAt = DateTime.now();
      final owner = await store.read('pin.owner');
      if (owner != response.user?.id && lock.hasPin) {
        await lock.vault.clear();
        lock.hasPin = false;
      }
      ownerMatches = owner == response.user?.id;
      deviceAuthorized = false;
      await refreshDeviceAccess(initial: true);
      if (_disposed || generation != _loginGeneration) throw StateError('Sign-in cancelled');
      final codes = data['recovery_codes'];
      if (codes is List && codes.length == 8 &&
          codes.every((code) => code is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(code))) {
        recoveryCodes = List<String>.from(codes);
      }
      if (!_disposed) notifyListeners();
    } finally { _accountBusy = false; }
  }

  Future<void> signIn(String userId, String password) => _authenticateAccount({
    'action': 'login', 'user_id': AccountInput.userId(userId), 'password': password,
  });

  Future<void> signUp(String username, String displayName, String mobile,
      String password, String confirmation) async {
    AccountInput.password(password, confirmation);
    await _authenticateAccount({
      'action': 'signup', 'username': AccountInput.username(username),
      'display_name': AccountInput.displayName(displayName),
      'recovery_phone': AccountInput.recoveryPhone(mobile),
      'password': password, 'confirm_password': confirmation,
    });
  }

  Future<void> recoverAccount(String userId, String code, String password, String confirmation) async {
    AccountInput.password(password, confirmation);
    final device = const Uuid().v4();
    await _authenticateAccount({
      'action': 'recover', 'user_id': AccountInput.userId(userId),
      'recovery_code': code.trim(), 'password': password,
      'confirm_password': confirmation, 'device_id': device,
    }, recoveredDevice: device);
  }

  Future<void> rotateRecoveryCodes(String password) async {
    if (!signedIn || !deviceAuthorized) throw StateError('Approved sign-in required');
    final owner = client!.auth.currentUser!.id;
    final session = tokenSession(client!.auth.currentSession);
    final data = await _accountRequest({'action': 'rotate_codes', 'password': password});
    if (!signedIn || !deviceAuthorized || client!.auth.currentUser!.id != owner ||
        tokenSession(client!.auth.currentSession) != session) {
      throw StateError('Session changed');
    }
    final codes = data['recovery_codes'];
    if (codes is! List || codes.length != 8 ||
        !codes.every((code) => code is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(code))) {
      throw StateError('Recovery codes unavailable');
    }
    recoveryCodes = List<String>.from(codes);
    notifyListeners();
  }

  void acknowledgeRecoveryCodes() {
    recoveryCodes = const [];
    notifyListeners();
  }

  Future<void> reauthenticate(String password) async {
    final owner = client?.auth.currentUser?.id;
    final session = tokenSession(client?.auth.currentSession);
    if (!signedIn || !deviceAuthorized) {
      throw StateError('Approved sign-in required');
    }
    await deviceAccess.manage('reauthenticate', password);
    if (_disposed ||
        !signedIn ||
        !deviceAuthorized ||
        client?.auth.currentUser?.id != owner ||
        tokenSession(client?.auth.currentSession) != session) {
      throw StateError('Session changed');
    }
    _freshUser = owner;
    _freshAt = DateTime.now();
    lock.lock();
    notifyListeners();
  }

  Future<void> configurePin(String pin, {bool openMessenger = false}) async {
    if (!recentlyAuthenticated || !deviceAuthorized) {
      throw StateError('Sign in again before setting a PIN');
    }
    final owner = client!.auth.currentUser!.id;
    final session = tokenSession(client!.auth.currentSession);
    final generation = _loginGeneration;
    await lock.vault.configure(pin);
    if (!signedIn || !deviceAuthorized || client!.auth.currentUser!.id != owner ||
        tokenSession(client!.auth.currentSession) != session || generation != _loginGeneration) {
      lock.lock();
      throw StateError('Session changed during PIN setup');
    }
    await store.write('pin.owner', owner);
    lock.hasPin = true;
    ownerMatches = true;
    await lock.initialize();
    lock.lock();
    if (openMessenger && signedIn && deviceAuthorized && recentlyAuthenticated &&
        client!.auth.currentUser!.id == owner && tokenSession(client!.auth.currentSession) == session &&
        generation == _loginGeneration) {
      await lock.unlock(pin);
    }
    notifyListeners();
  }

  Future<void> signOut() async {
    ++_loginGeneration;
    lock.lock();
    recoveryCodes = const [];
    _freshUser = null;
    final revoking = client == null
        ? Future<void>.value()
        : deviceAccess.revokeCurrent().catchError((Object _) {});
    deviceAuthorized = false;
    await client?.auth.signOut();
    await revoking;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_loginGeneration;
    recoveryCodes = const [];
    _expiry?.cancel();
    ++_accessGeneration;
    _subscription?.cancel();
    _unsubscribeDeviceRealtime();
    _accountGateway?.close();
    super.dispose();
  }
}
