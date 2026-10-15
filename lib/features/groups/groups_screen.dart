import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/widgets/actions.dart';
import '../../core/widgets/private_scaffold.dart';
import '../../providers/app_providers.dart';

class GroupsScreen extends ConsumerStatefulWidget {
  const GroupsScreen({super.key});
  @override
  ConsumerState<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends ConsumerState<GroupsScreen> {
  late final stream = ref.read(messengerProvider).watch(
    ['conversations', 'conversation_members', 'group_invitations'],
    () async {
      final client = ref.read(supabaseProvider);
      return {
        'groups': await client.from('groups').select(),
        'invitations': await client
            .from('group_invitations')
            .select()
            .eq('invitee_id', client.auth.currentUser!.id)
            .isFilter('accepted_at', null)
            .gt('expires_at', DateTime.now().toUtc().toIso8601String()),
      };
    },
  );
  @override
  Widget build(BuildContext context) => PrivateScaffold(
    title: 'Groups',
    index: 3,
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => act(context, () async {
        final title = await askText(context, 'Group name');
        if (title == null) return;
        final cid = await ref
            .read(supabaseProvider)
            .rpc('create_group', params: {'title': title});
        if (context.mounted) context.push('/details/$cid');
      }),
      icon: const Icon(Icons.group_add_outlined),
      label: const Text('Create group'),
    ),
    body: StreamBuilder<Map<String, List<Map<String, dynamic>>>>(
      stream: stream,
      builder: (context, s) {
        if (s.hasError) return LoadError(retry: () => context.go('/groups'));
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        final groups = s.data!['groups']!, invites = s.data!['invitations']!;
        return ListView(
          children: [
            if (invites.isNotEmpty) const ListTile(title: Text('Invitations')),
            for (final i in invites)
              ListTile(
                leading: const Icon(Icons.mail_outline),
                title: const Text('Group invitation'),
                subtitle: Text('Expires ${i['expires_at']}'),
                trailing: TextButton(
                  onPressed: () => act(context, () async {
                    final cid = await ref
                        .read(supabaseProvider)
                        .rpc('accept_invitation', params: {'iid': i['id']});
                    if (context.mounted) context.push('/chat/$cid');
                  }),
                  child: const Text('Accept'),
                ),
              ),
            if (groups.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Bring your people together. Create a group or accept an invitation.',
                ),
              ),
            for (final g in groups)
              ListTile(
                leading: PersonAvatar(
                  name: g['name'],
                  path: g['avatar_path'],
                  bucket: 'chat-media',
                ),
                title: Text(g['name']),
                subtitle: Text(g['description']),
                onTap: () => context.push('/chat/${g['conversation_id']}'),
              ),
          ],
        );
      },
    ),
  );
}
