import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../providers/app_providers.dart';
import '../../core/widgets/private_scaffold.dart';
import '../../core/widgets/actions.dart';

class CallHistoryScreen extends ConsumerStatefulWidget {
  const CallHistoryScreen({super.key});
  @override
  ConsumerState<CallHistoryScreen> createState() => _CallHistoryScreenState();
}

class _CallHistoryScreenState extends ConsumerState<CallHistoryScreen> {
  late final stream = ref.read(messengerProvider).watch(
    ['calls'],
    () async => await ref
        .read(supabaseProvider)
        .from('calls')
        .select()
        .order('created_at', ascending: false)
        .limit(100),
  );
  @override
  Widget build(BuildContext context) => PrivateScaffold(
    title: 'Calls',
    index: 2,
    body: StreamBuilder<List<Map<String, dynamic>>>(
      stream: stream,
      builder: (context, s) {
        if (s.hasError) return LoadError(retry: () => context.go('/calls'));
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        if (s.data!.isEmpty) {
          return const Center(
            child: Text(
              'Your calls will appear here. Start a call from a conversation.',
            ),
          );
        }
        return ListView(
          children: [
            for (final c in s.data!)
              ListTile(
                leading: Icon(
                  c['video'] ? Icons.videocam_outlined : Icons.call_outlined,
                ),
                title: Text(c['state']),
                subtitle: Text(
                  DateFormat.yMMMd().add_Hm().format(
                    DateTime.parse(c['created_at']).toLocal(),
                  ),
                ),
                onTap: () => context.push('/call/${c['id']}'),
              ),
          ],
        );
      },
    ),
  );
}
