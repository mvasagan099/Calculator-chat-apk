import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../providers/app_providers.dart';

class GroupAuditLogSheet extends ConsumerWidget {
  const GroupAuditLogSheet({super.key, required this.conversationId});
  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(supabaseProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.admin_panel_settings_outlined),
                  const SizedBox(width: 10),
                  Text(
                    'Admin Action History',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(),
            Flexible(
              child: FutureBuilder<List<Map<String, dynamic>>>(
                future: client
                    .from('group_audit_logs')
                    .select('*, actor:actor_id(display_name, username), target:target_id(display_name, username)')
                    .eq('conversation_id', conversationId)
                    .order('created_at', ascending: false)
                    .limit(50),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }

                  final logs = snapshot.data ?? [];
                  if (logs.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(
                        child: Text(
                          'No administrative actions recorded yet.',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    );
                  }

                  return ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    itemCount: logs.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final log = logs[i];
                      final action = log['action'] as String? ?? 'action';
                      final actorName = log['actor']?['display_name'] ?? 'Admin';
                      final targetName = log['target']?['display_name'];
                      final createdAt = DateTime.tryParse(log['created_at'] ?? '')?.toLocal();
                      final formattedDate = createdAt != null
                          ? DateFormat.yMMMd().add_jm().format(createdAt)
                          : '';

                      final description = switch (action) {
                        'promote' => '$actorName made $targetName an admin',
                        'demote' => '$actorName removed admin role from $targetName',
                        'remove' => '$actorName removed $targetName from group',
                        'mute' => '$actorName muted $targetName',
                        'unmute' => '$actorName unmuted $targetName',
                        'transfer_ownership' => '$actorName transferred group ownership to $targetName',
                        'slow_mode' => '$actorName updated slow mode to ${log['details']?['seconds'] ?? 0}s',
                        'set_permissions' => '$actorName modified group member permissions',
                        'name' => '$actorName changed group name to "${log['details']?['value'] ?? ''}"',
                        'description' => '$actorName updated group description',
                        'avatar' => '$actorName changed group icon',
                        _ => '$actorName performed $action',
                      };

                      return ListTile(
                        leading: CircleAvatar(
                          child: Icon(_actionIcon(action), size: 18),
                        ),
                        title: Text(description),
                        subtitle: Text(formattedDate, style: const TextStyle(fontSize: 12)),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _actionIcon(String action) => switch (action) {
    'promote' || 'transfer_ownership' => Icons.star_border,
    'demote' => Icons.arrow_downward,
    'remove' => Icons.person_remove_outlined,
    'mute' => Icons.volume_off_outlined,
    'unmute' => Icons.volume_up_outlined,
    'slow_mode' => Icons.timer_outlined,
    'set_permissions' => Icons.security,
    _ => Icons.edit_outlined,
  };
}
