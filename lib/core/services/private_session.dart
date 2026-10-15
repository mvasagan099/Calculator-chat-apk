import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers/app_providers.dart';
import 'auth_service.dart';
import '../../repositories/messenger_repository.dart';
import '../../features/notifications/notification_service.dart';

class PrivateSession extends ConsumerStatefulWidget {
  const PrivateSession({
    super.key,
    required this.child,
    required this.router,
    required this.notifications,
    required this.auth,
  });
  final Widget child;
  final GoRouter router;
  final NotificationService notifications;
  final AuthService auth;
  @override
  ConsumerState<PrivateSession> createState() => _PrivateSessionState();
}

class _PrivateSessionState extends ConsumerState<PrivateSession> {
  final subscriptions = <StreamSubscription>[];
  Timer? heartbeat;
  MessengerRepository? repository;
  final handled = <String>{};
  @override
  void initState() {
    super.initState();
    Future.microtask(start);
  }

  Future<void> start() async {
    if (!mounted) return;
    final client = ref.read(supabaseProvider);
    final repo = ref.read(messengerProvider);
    repository = repo;
    final owner = client.auth.currentUser?.id;
    if (owner == null) return;
    bool active() =>
        mounted &&
        widget.auth.deviceAuthorized &&
        client.auth.currentUser?.id == owner;
    try {
      await repo.prepare();
      if (!active()) return;
      final settings = await client
          .from('user_settings')
          .select()
          .eq('user_id', owner)
          .single();
      if (!active()) return;
      if (settings['notifications'] == true) {
        await widget.notifications.register(client);
      }
      if (!active()) return;
      subscriptions.add(
        client
            .from('account_devices')
            .stream(primaryKey: ['id'])
            .eq('user_id', owner)
            .listen((_) {
              if (mounted) unawaited(widget.auth.refreshDeviceAccess());
            }, onError: (Object _) {}),
      );
      void beat() {
        if (!active()) return;
        unawaited(widget.auth.refreshDeviceAccess());
        unawaited(client.rpc('device_heartbeat').catchError((Object _) {}));
        unawaited(
          client
              .from('user_settings')
              .update({
                'last_seen_at': DateTime.now().toUtc().toIso8601String(),
              })
              .eq('user_id', owner)
              .then((_) {})
              .catchError((Object _) {}),
        );
      }

      beat();
      heartbeat = Timer.periodic(const Duration(minutes: 1), (_) => beat());
      subscriptions.add(
        client
            .from('calls')
            .stream(primaryKey: ['id'])
            .eq('state', 'ringing')
            .listen((rows) {
              if (!active()) return;
              for (final call in rows) {
                if (call['caller_id'] != owner &&
                    DateTime.now().difference(
                          DateTime.parse(call['created_at']),
                        ) <
                        const Duration(seconds: 45) &&
                    handled.add(call['id'])) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (active() && ref.read(lockProvider).unlocked) {
                      widget.router.push('/call/${call['id']}');
                    }
                  });
                  break;
                }
              }
            }),
      );
      subscriptions.add(
        client
            .from('messages')
            .stream(primaryKey: ['id'])
            .order('created_at', ascending: false)
            .limit(100)
            .listen((rows) {
              if (!active()) return;
              for (final cid
                  in rows
                      .where((m) => m['sender_id'] != owner)
                      .map((m) => m['conversation_id'])
                      .toSet()) {
                unawaited(
                  client
                      .rpc(
                        'ack_messages',
                        params: {'cid': cid, 'mark_read': false},
                      )
                      .catchError((Object _) {}),
                );
              }
            }),
      );
    } catch (_) {
      /* Individual screens expose retryable connection errors. */
    }
  }

  @override
  void dispose() {
    for (final subscription in subscriptions) {
      subscription.cancel();
    }
    heartbeat?.cancel();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    unawaited(
      repository?.suspend().catchError((Object _) {}) ?? Future.value(),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
