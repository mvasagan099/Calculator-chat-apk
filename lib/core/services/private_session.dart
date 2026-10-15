import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers/app_providers.dart';
import '../../features/notifications/notification_service.dart';

class PrivateSession extends ConsumerStatefulWidget {
  const PrivateSession({
    super.key,
    required this.child,
    required this.router,
    required this.notifications,
  });
  final Widget child;
  final GoRouter router;
  final NotificationService notifications;
  @override
  ConsumerState<PrivateSession> createState() => _PrivateSessionState();
}

class _PrivateSessionState extends ConsumerState<PrivateSession> {
  final subscriptions = <StreamSubscription>[];
  Timer? heartbeat;
  final handled = <String>{};
  @override
  void initState() {
    super.initState();
    Future.microtask(start);
  }

  Future<void> start() async {
    final client = ref.read(supabaseProvider);
    final repo = ref.read(messengerProvider);
    try {
      await repo.prepare();
      if (!mounted) return;
      final settings = await client
          .from('user_settings')
          .select()
          .eq('user_id', repo.uid)
          .single();
      if (settings['notifications'] == true) {
        await widget.notifications.register(client);
      }
      void beat() {
        if (!mounted) return;
        unawaited(
          client
              .from('user_settings')
              .update({
                'last_seen_at': DateTime.now().toUtc().toIso8601String(),
              })
              .eq('user_id', repo.uid)
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
              for (final call in rows) {
                if (call['caller_id'] != repo.uid &&
                    DateTime.now().difference(
                          DateTime.parse(call['created_at']),
                        ) <
                        const Duration(seconds: 45) &&
                    handled.add(call['id'])) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && ref.read(lockProvider).unlocked) {
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
              for (final cid
                  in rows
                      .where((m) => m['sender_id'] != repo.uid)
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
