import 'dart:convert';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:calculator_messenger/core/security/lock_controller.dart';
import 'package:calculator_messenger/core/services/device_settings.dart';
import 'package:calculator_messenger/features/notifications/notification_service.dart';
import 'lock_biometric_test.dart' show ImmediatePinVault;

class RecordingNotifications implements FlutterLocalNotificationsPlugin {
  final shown = <Map<String, dynamic>>[];
  final channels = <AndroidNotificationChannel>[];

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async {
    shown.add({
      'id': id,
      'title': title,
      'body': body,
      'details': notificationDetails,
      'payload': payload,
    });
  }

  @override
  T? resolvePlatformSpecificImplementation<T extends Object>() {
    if (T == AndroidFlutterLocalNotificationsPlugin) {
      return FakeAndroidNotifications(channels) as T;
    }
    return null;
  }

  @override
  Future<void> cancelAll() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected call: ${invocation.memberName}');
}

class FakeAndroidNotifications
    implements AndroidFlutterLocalNotificationsPlugin {
  FakeAndroidNotifications(this.channels);
  final List<AndroidNotificationChannel> channels;

  @override
  Future<void> createNotificationChannel(
      AndroidNotificationChannel channel) async {
    channels.add(channel);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected call: ${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RecordingNotifications local;
  late SharedPreferences prefs;
  late LockController lock;
  late DeviceSettings settings;

  setUp(() async {
    local = RecordingNotifications();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    lock = LockController(ImmediatePinVault());
    settings = DeviceSettings(prefs, lock);
  });

  tearDown(() {
    lock.dispose();
  });

  group('DeviceSettings notification privacy', () {
    test('defaults to generic privacy', () {
      expect(settings.notificationPrivacy, NotificationPrivacy.generic);
    });

    test('updates and persists detailed and silent settings', () async {
      await settings.setNotificationPrivacy(NotificationPrivacy.detailed);
      expect(settings.notificationPrivacy, NotificationPrivacy.detailed);

      await settings.setNotificationPrivacy(NotificationPrivacy.silent);
      expect(settings.notificationPrivacy, NotificationPrivacy.silent);
    });
  });

  group('showIncomingCall with privacy levels', () {
    const callActivity = {
      'kind': 'call',
      'resource_id': '12345678-1234-1234-1234-123456789abc',
    };

    test('detailed privacy reveals caller name and uses incoming_calls channel', () async {
      final futureDeadline = DateTime.now().add(const Duration(seconds: 30)).toIso8601String();

      await showIncomingCall(
        local,
        callActivity,
        futureDeadline,
        privacy: NotificationPrivacy.detailed,
        callerName: 'Alice Smith',
      );

      expect(local.shown.length, 1);
      final notif = local.shown.first;
      expect(notif['title'], 'Calculator');
      expect(notif['body'], 'Incoming call from Alice Smith');

      final details = notif['details'] as NotificationDetails;
      final androidDetails = details.android!;
      expect(androidDetails.channelId, 'incoming_calls');
      expect(androidDetails.importance, Importance.max);
      expect(androidDetails.playSound, isTrue);
      expect(androidDetails.enableVibration, isTrue);
    });

    test('generic privacy hides caller name and shows New activity', () async {
      final futureDeadline = DateTime.now().add(const Duration(seconds: 30)).toIso8601String();

      await showIncomingCall(
        local,
        callActivity,
        futureDeadline,
        privacy: NotificationPrivacy.generic,
        callerName: 'Alice Smith', // Caller name should be suppressed
      );

      expect(local.shown.length, 1);
      final notif = local.shown.first;
      expect(notif['title'], 'Calculator');
      expect(notif['body'], 'New activity');

      final details = notif['details'] as NotificationDetails;
      final androidDetails = details.android!;
      expect(androidDetails.channelId, 'incoming_calls');
      expect(androidDetails.importance, Importance.max);
    });

    test('silent privacy routes to silent_calls channel without sound or vibration', () async {
      final futureDeadline = DateTime.now().add(const Duration(seconds: 30)).toIso8601String();

      await showIncomingCall(
        local,
        callActivity,
        futureDeadline,
        privacy: NotificationPrivacy.silent,
      );

      expect(local.shown.length, 1);
      final notif = local.shown.first;
      final details = notif['details'] as NotificationDetails;
      final androidDetails = details.android!;
      expect(androidDetails.channelId, 'silent_calls');
      expect(androidDetails.importance, Importance.low);
      expect(androidDetails.priority, Priority.low);
      expect(androidDetails.playSound, isFalse);
      expect(androidDetails.enableVibration, isFalse);
    });

    test('expired deadline suppresses notification display entirely', () async {
      final pastDeadline = DateTime.now().subtract(const Duration(seconds: 5)).toIso8601String();

      await showIncomingCall(
        local,
        callActivity,
        pastDeadline,
        privacy: NotificationPrivacy.detailed,
      );

      expect(local.shown, isEmpty);
    });
  });

  group('showMissedCall with privacy levels', () {
    const missedActivity = {
      'kind': 'missed_call',
      'resource_id': '12345678-1234-1234-1234-123456789abc',
    };

    test('detailed privacy displays missed call with caller name', () async {
      await showMissedCall(
        local,
        missedActivity,
        privacy: NotificationPrivacy.detailed,
        callerName: 'Charlie',
      );

      expect(local.shown.length, 1);
      final notif = local.shown.first;
      expect(notif['body'], 'Missed call from Charlie');

      final details = notif['details'] as NotificationDetails;
      final androidDetails = details.android!;
      expect(androidDetails.channelId, 'missed_calls');
      expect(androidDetails.importance, Importance.high);
      expect(androidDetails.playSound, isTrue);
    });

    test('generic privacy suppresses caller identity', () async {
      await showMissedCall(
        local,
        missedActivity,
        privacy: NotificationPrivacy.generic,
        callerName: 'Charlie',
      );

      expect(local.shown.length, 1);
      final notif = local.shown.first;
      expect(notif['body'], 'New activity');

      final details = notif['details'] as NotificationDetails;
      final androidDetails = details.android!;
      expect(androidDetails.channelId, 'missed_calls');
    });

    test('silent privacy routes to silent_activity without alert', () async {
      await showMissedCall(
        local,
        missedActivity,
        privacy: NotificationPrivacy.silent,
      );

      expect(local.shown.length, 1);
      final notif = local.shown.first;
      final details = notif['details'] as NotificationDetails;
      final androidDetails = details.android!;
      expect(androidDetails.channelId, 'silent_activity');
      expect(androidDetails.importance, Importance.low);
      expect(androidDetails.playSound, isFalse);
      expect(androidDetails.enableVibration, isFalse);
    });
  });

  group('NotificationService privacy integration', () {
    test('bindSettings links privacy configuration to NotificationService', () {
      final notifService = NotificationService(local: local, settings: settings);
      expect(notifService.privacy, NotificationPrivacy.generic);

      settings.setNotificationPrivacy(NotificationPrivacy.detailed);
      expect(notifService.privacy, NotificationPrivacy.detailed);

      settings.setNotificationPrivacy(NotificationPrivacy.silent);
      expect(notifService.privacy, NotificationPrivacy.silent);
    });
  });
}
