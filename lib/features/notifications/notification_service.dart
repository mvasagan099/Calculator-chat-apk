import 'dart:async';
import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/config/app_config.dart';
import 'notification_activity.dart';
import 'app_update.dart';
import '../../core/services/auth_service.dart';

Future<void> initializeFirebase() async {
  if (Firebase.apps.isEmpty) {
    // Android can read the Google Services plugin's native resources. Explicit
    // options, when supplied by the config preparer, match the same console file.
    await Firebase.initializeApp(
      options: AppConfig.firebaseConfigured ? AppConfig.firebaseOptions : null,
    );
  }
}

@pragma('vm:entry-point')
Future<void> backgroundActivity(RemoteMessage message) async {
  await initializeFirebase();
  final activity = NotificationActivity.parse(message.data);
  if (activity?['kind'] == 'call') {
    final local = FlutterLocalNotificationsPlugin();
    await local.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_notification'),
      ),
    );
    await showIncomingCall(local, activity!, message.data['expires_at']);
  }
  // Other notification payloads are rendered by Android. Never fetch messages,
  // credentials or room tokens, nor start microphone/camera capture here.
}

Future<void> showIncomingCall(
  FlutterLocalNotificationsPlugin local,
  Map<String, dynamic> activity,
  dynamic expires,
) async {
  final deadline = DateTime.tryParse(expires is String ? expires : '');
  // Missing/stale TTL is not permission to ring a delayed invitation.
  if (deadline == null || !deadline.isAfter(DateTime.now())) return;
  await local
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(
        const AndroidNotificationChannel(
          'incoming_calls',
          'Incoming calls',
          importance: Importance.max,
        ),
      );
  await local.show(
    id: activity['resource_id'].hashCode & 0x7fffffff,
    title: 'Calculator',
    body: 'New activity',
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        'incoming_calls',
        'Incoming calls',
        importance: Importance.max,
        priority: Priority.high,
        visibility: NotificationVisibility.private,
        category: AndroidNotificationCategory.call,
        timeoutAfter: deadline
            .difference(DateTime.now())
            .inMilliseconds
            .clamp(1, 45000),
        actions: const [
          AndroidNotificationAction(
            'answer',
            'Unlock to answer',
            showsUserInterface: true,
            cancelNotification: true,
          ),
          AndroidNotificationAction(
            'reject',
            'Unlock to reject',
            showsUserInterface: true,
            cancelNotification: true,
          ),
        ],
      ),
    ),
    payload: jsonEncode(activity),
  );
}

class NotificationService extends ChangeNotifier {
  NotificationService({FlutterLocalNotificationsPlugin? local})
      : local = local ?? FlutterLocalNotificationsPlugin();
  final FlutterLocalNotificationsPlugin local;
  SupabaseClient? _client;
  StreamSubscription<AuthState>? _accountChanges;
  String? _boundOwner;
  final _shown = <String>{}, _showing = <String>{};
  VerifiedAppUpdate? _update;
  String? _updateOwner;
  VerifiedAppUpdate? get availableUpdate => _updateOwner != null &&
      _updateOwner == _client?.auth.currentUser?.id ? _update : null;
  static const _identity = MethodChannel('calculator_messenger/privacy');

  void bindClient(SupabaseClient client) {
    if (identical(_client, client)) return;
    _accountChanges?.cancel();
    _client = client;
    _boundOwner = client.auth.currentUser?.id;
    _accountChanges = client.auth.onAuthStateChange.listen((event) {
      if (_boundOwner == event.session?.user.id) return;
      _boundOwner = event.session?.user.id;
      pending = null;
      _shown.clear(); _update = null; _updateOwner = null;
      unawaited(local.cancelAll().catchError((Object _) {}));
      if (!_disposed) notifyListeners();
    });
  }

  void _receive(Map<String, dynamic> data) {
    final activity = NotificationActivity.parse(data);
    final owner = _client?.auth.currentUser?.id;
    if (activity == null || (activity['recipient_id'] != null && activity['recipient_id'] != owner)) return;
    pending = {...activity, if (owner != null) 'recipient_id': owner};
    if (!_disposed) notifyListeners();
  }

  Future<void> handleForeground(RemoteMessage message) async {
    final activity = NotificationActivity.parse(message.data);
    if (_disposed || activity == null || activity['kind'] == 'app_update') return;
    if (activity['recipient_id'] != null && activity['recipient_id'] != _client?.auth.currentUser?.id) return;
    if (activity['kind'] == 'call') {
      await showIncomingCall(local, activity, message.data['expires_at']);
      return;
    }
    final client = _client;
    final owner = client?.auth.currentUser?.id;
    final session = AuthService.tokenSession(client?.auth.currentSession);
    if (client == null || owner == null || session == null || client.auth.currentSession?.isExpired != false ||
        (activity['recipient_id'] != null && activity['recipient_id'] != owner)) return;
    final key = '$owner:${NotificationActivity.tag(activity)}';
    if (_shown.contains(key) || _showing.length >= 64 || !_showing.add(key)) return;
    try {
      if (activity['kind'] == 'message') {
        final target = await client.rpc('notification_message_target', params: {'mid': activity['resource_id']})
            .timeout(const Duration(seconds: 10));
        if (target == null) return;
      } else {
        final settings = await client.from('user_settings').select('notifications').eq('user_id', owner).single();
        if (settings['notifications'] != true) return;
      }
      if (_disposed || client.auth.currentUser?.id != owner ||
          AuthService.tokenSession(client.auth.currentSession) != session || client.auth.currentSession?.isExpired != false) return;
      await local.show(
        id: 0, title: 'Calculator', body: NotificationActivity.body(activity),
        notificationDetails: NotificationDetails(android: AndroidNotificationDetails(
          'activity', 'Calculator updates', icon: 'ic_notification',
          tag: NotificationActivity.tag(activity), onlyAlertOnce: true,
          importance: Importance.high, priority: Priority.high,
          visibility: NotificationVisibility.private,
        )), payload: jsonEncode({...activity, 'recipient_id': owner}),
      );
      _shown.add(key);
      if (_shown.length > 256) _shown.remove(_shown.first);
    } catch (_) { /* Offline/unauthorized relevance checks fail closed. */ }
    finally { _showing.remove(key); }
  }

  Future<VerifiedAppUpdate?> verifyAppUpdate() async {
    final client = _client;
    final owner = client?.auth.currentUser?.id;
    final session = AuthService.tokenSession(client?.auth.currentSession);
    if (client == null || owner == null || session == null || client.auth.currentSession?.isExpired != false) return null;
    try {
      final installed = await _identity.invokeMapMethod<String, dynamic>('appIdentity').timeout(const Duration(seconds: 2));
      if (installed == null) return null;
      final manifest = await client.rpc('latest_android_release', params: {'target_abi': installed['abi']})
          .timeout(const Duration(seconds: 10));
      if (_disposed || client.auth.currentUser?.id != owner || AuthService.tokenSession(client.auth.currentSession) != session) return null;
      _update = VerifiedAppUpdate.parse(installed, manifest);
      _updateOwner = owner;
      return _update;
    } catch (_) {
      if (client.auth.currentUser?.id == owner) { _update = null; _updateOwner = null; }
      return null;
    }
  }

  Future<void> checkForAppUpdate() async {
    final originalOwner = _client?.auth.currentUser?.id;
    final session = AuthService.tokenSession(_client?.auth.currentSession);
    final update = await verifyAppUpdate();
    final owner = _client?.auth.currentUser?.id;
    if (update == null || owner == null || owner != originalOwner ||
        session != AuthService.tokenSession(_client?.auth.currentSession)) return;
    final key = '$owner:app_update:${update.id}';
    if (_shown.contains(key) || !_showing.add(key)) return;
    try {
      final settings = await _client!.from('user_settings').select('notifications').eq('user_id', owner).single();
      if (settings['notifications'] != true || _disposed || _client?.auth.currentUser?.id != owner) return;
      await local.show(id: 0, title: 'Calculator', body: 'Update to the latest version',
        notificationDetails: NotificationDetails(android: AndroidNotificationDetails(
          'activity', 'Calculator updates', icon: 'ic_notification', tag: 'app_update:${update.id}',
          onlyAlertOnce: true, visibility: NotificationVisibility.private,
        )), payload: jsonEncode({'kind': 'app_update', 'resource_id': update.id, 'recipient_id': owner}));
      _shown.add(key);
      if (_shown.length > 256) _shown.remove(_shown.first);
      if (!_disposed) notifyListeners();
    } catch (_) { /* No verified release means no version warning. */ }
    finally { _showing.remove(key); }
  }
  bool available = false;
  String? token;
  int _registrationGeneration = 0;
  bool _disposed = false;
  Map<String, dynamic>? pending;
  final subscriptions = <StreamSubscription>[];
  StreamSubscription<String>? registration;
  Future<void> initialize() async {
    await local.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_notification'),
      ),
      onDidReceiveNotificationResponse: (response) {
        try {
          _receive({
            ...jsonDecode(response.payload ?? '{}') as Map<String, dynamic>,
            'action': response.actionId,
          });
        } catch (_) {}
      },
    );
    final android = local
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        'activity',
        'Calculator updates',
        description: 'Calculator notifications',
        importance: Importance.high,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        'incoming_calls',
        'Incoming calls',
        description: 'Private incoming calls',
        importance: Importance.max,
      ),
    );
    final launch = await local.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true) {
      try {
        _receive({
          ...jsonDecode(launch!.notificationResponse?.payload ?? '{}')
              as Map<String, dynamic>,
          'action': launch.notificationResponse?.actionId,
        });
      } catch (_) {}
    }
    if (!AppConfig.firebaseConfigured &&
        (kIsWeb || defaultTargetPlatform != TargetPlatform.android)) {
      return;
    }
    try {
      await initializeFirebase();
      available = true;
      FirebaseMessaging.onBackgroundMessage(backgroundActivity);
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) _receive(initial.data);
      subscriptions.add(
        FirebaseMessaging.onMessageOpenedApp.listen((m) {
          _receive(m.data);
        }),
      );
      subscriptions.add(
        FirebaseMessaging.onMessage.listen(handleForeground),
      );
    } catch (_) {
      available = false;
    }
  }

  Future<void> register(SupabaseClient client, {bool request = false}) async {
    bindClient(client);
    if (_disposed || !available || client.auth.currentUser == null) return;
    final uid = client.auth.currentUser!.id;
    final generation = ++_registrationGeneration;
    final settings = request
        ? await FirebaseMessaging.instance.requestPermission()
        : await FirebaseMessaging.instance.getNotificationSettings();
    if (settings.authorizationStatus != AuthorizationStatus.authorized ||
        _disposed ||
        generation != _registrationGeneration ||
        client.auth.currentUser?.id != uid) {
      return;
    }
    await registration?.cancel();
    if (_disposed ||
        generation != _registrationGeneration ||
        client.auth.currentUser?.id != uid) {
      return;
    }
    registration = FirebaseMessaging.instance.onRegistered.listen((
      newToken,
    ) async {
      if (_disposed ||
          generation != _registrationGeneration ||
          client.auth.currentUser?.id != uid) {
        return;
      }
      token = newToken;
      if (client.auth.currentUser?.id == uid) {
        try {
          await client.from('push_tokens').upsert({
            'user_id': uid,
            'token': newToken,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          });
        } catch (_) {}
      }
    });
    await FirebaseMessaging.instance.register();
  }

  Future<void> unregister(SupabaseClient client) async {
    pending = null; _shown.clear(); _update = null; _updateOwner = null;
    ++_registrationGeneration;
    final previous = token;
    final uid = client.auth.currentUser?.id;
    token = null;
    await registration?.cancel();
    registration = null;
    // An offline database delete must not prevent local unregistration/logout.
    try {
      if (previous != null && uid != null) {
        await client
            .from('push_tokens')
            .delete()
            .eq('user_id', uid)
            .eq('token', previous);
      }
    } catch (_) {
      // Stale server rows expire; all server payloads remain generic and RLS
      // still requires the current account for any subsequent activity lookup.
    } finally {
      try {
        if (available) await FirebaseMessaging.instance.unregister();
      } finally {
        await local.cancelAll();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _accountChanges?.cancel();
    ++_registrationGeneration;
    registration?.cancel();
    for (final s in subscriptions) {
      s.cancel();
    }
    super.dispose();
  }
}
