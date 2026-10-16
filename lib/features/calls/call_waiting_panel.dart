import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers/app_providers.dart';
import '../../core/widgets/actions.dart';
import 'call_controller.dart';

class CallWaitingPanel extends ConsumerStatefulWidget {
  const CallWaitingPanel({
    super.key,
    required this.current,
    required this.controller,
  });
  final String current;
  final CallController controller;
  @override
  ConsumerState<CallWaitingPanel> createState() => _CallWaitingPanelState();
}

class _CallWaitingPanelState extends ConsumerState<CallWaitingPanel> {
  late final stream = ref.read(messengerProvider).watch(
    ['calls'],
    () async => await ref
        .read(supabaseProvider)
        .from('call_participants')
        .select('call_id,calls!inner(state,video)')
        .eq('user_id', ref.read(supabaseProvider).auth.currentUser!.id)
        .eq('state', 'invited')
        .gt('invitation_expires_at', DateTime.now().toUtc().toIso8601String()),
  );
  @override
  Widget build(
    BuildContext context,
  ) => StreamBuilder<List<Map<String, dynamic>>>(
    stream: stream,
    builder: (context, snapshot) {
      final waiting = snapshot.data
          ?.where(
            (p) =>
                p['call_id'] != widget.current &&
                ['ringing', 'accepted'].contains(p['calls']?['state']),
          )
          .firstOrNull;
      if (waiting == null || widget.controller.finished) {
        return const SizedBox.shrink();
      }
      return Card(
        child: ListTile(
          leading: const Icon(Icons.call_received),
          title: const Text('Another incoming call'),
          subtitle: const Text('End the current call before answering.'),
          trailing: PopupMenuButton<String>(
            onSelected: (action) => act(context, () async {
              if (action == 'busy') {
                await ref
                    .read(supabaseProvider)
                    .functions
                    .invoke(
                      'call-control',
                      body: {'call_id': waiting['call_id'], 'action': 'busy'},
                    );
              } else {
                await widget.controller.end();
                await widget.controller.reset();
                if (context.mounted && ref.read(lockProvider).unlocked) {
                  context.go('/call/${waiting['call_id']}');
                }
              }
            }),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'busy', child: Text('Decline waiting call')),
              PopupMenuItem(
                value: 'review',
                child: Text('End current and review'),
              ),
            ],
          ),
        ),
      );
    },
  );
}
