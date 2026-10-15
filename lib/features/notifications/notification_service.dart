import 'dart:async';
import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/config/app_config.dart';
import 'notification_activity.dart';

@pragma('vm:entry-point')
Future<void> backgroundActivity(RemoteMessage message) async {
  if (Firebase.apps.isEmpty && AppConfig.firebaseConfigured) {
    await Firebase.initializeApp(options: AppConfig.firebaseOptions);
  }
  // Notification payloads are rendered by Android. No private message data is
  // downloaded in this background isolate and no duplicate notification shown.
}

class NotificationService extends ChangeNotifier {
  final local = FlutterLocalNotificationsPlugin();
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
          pending = NotificationActivity.parse(
            jsonDecode(response.payload ?? '{}') as Map<String, dynamic>,
          );
          if (!_disposed && pending != null) notifyListeners();
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
        'Activity',
        description: 'Private activity notifications',
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
        pending = NotificationActivity.parse(
          jsonDecode(launch!.notificationResponse?.payload ?? '{}')
              as Map<String, dynamic>,
        );
      } catch (_) {}
    }
    if (!AppConfig.firebaseConfigured) return;
    try {
      await Firebase.initializeApp(options: AppConfig.firebaseOptions);
      available = true;
      FirebaseMessaging.onBackgroundMessage(backgroundActivity);
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) pending = NotificationActivity.parse(initial.data);
      subscriptions.add(
        FirebaseMessaging.onMessageOpenedApp.listen((m) {
          pending = NotificationActivity.parse(m.data);
          if (!_disposed && pending != null) notifyListeners();
        }),
      );
      subscriptions.add(
        FirebaseMessaging.onMessage.listen((message) async {
          if (_disposed) return;
          final activity = NotificationActivity.parse(message.data);
          if (activity == null) return;
          final call = activity['kind'] == 'call';
          await local.show(
            id: message.messageId.hashCode & 0x7fffffff,
            title: 'Calculator',
            body: 'New activity',
            notificationDetails: NotificationDetails(
              android: AndroidNotificationDetails(
                call ? 'incoming_calls' : 'activity',
                call ? 'Incoming calls' : 'Activity',
                importance: call ? Importance.max : Importance.high,
                priority: Priority.high,
                visibility: NotificationVisibility.private,
                category: call
                    ? AndroidNotificationCategory.call
                    : AndroidNotificationCategory.message,
              ),
            ),
            payload: jsonEncode(activity),
          );
        }),
      );
    } catch (_) {
      available = false;
    }
  }

  Future<void> register(SupabaseClient client, {bool request = false}) async {
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
    ++_registrationGeneration;
    registration?.cancel();
    for (final s in subscriptions) {
      s.cancel();
    }
    super.dispose();
  }
}
