import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/widgets/actions.dart';
import '../../core/widgets/private_scaffold.dart';
import '../../providers/app_providers.dart';
import '../../models/message.dart';
import '../media/attachment_view.dart';
import '../media/media_service.dart';

class ConversationDetailsScreen extends ConsumerStatefulWidget {
  const ConversationDetailsScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<ConversationDetailsScreen> createState() =>
      _ConversationDetailsScreenState();
}

class _ConversationDetailsScreenState
    extends ConsumerState<ConversationDetailsScreen> {
  late Future<Map<String, dynamic>> future = load();
  Future<Map<String, dynamic>> load() async {
    final c = ref.read(supabaseProvider);
    return {
      'conversation': await c
          .from('conversations')
          .select()
          .eq('id', widget.id)
          .single(),
      'group': await c
          .from('groups')
          .select()
          .eq('conversation_id', widget.id)
          .maybeSingle(),
      'members': await c
          .from('conversation_members')
          .select('*,profiles(*)')
          .eq('conversation_id', widget.id),
      'media': await c
          .from('messages')
          .select('*,message_attachments(*)')
          .eq('conversation_id', widget.id)
          .neq('kind', 'text')
          .isFilter('deleted_at', null)
          .order('created_at', ascending: false)
          .limit(100),
    };
  }

  Future<void> manage(String action, {String? target, String? value}) async {
    await ref
        .read(supabaseProvider)
        .rpc(
          'manage_group',
          params: {
            'cid': widget.id,
            'action': action,
            'target': target,
            'value': value,
          },
        );
    if (mounted) setState(() => future = load());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Conversation details')),
    body: FutureBuilder<Map<String, dynamic>>(
      future: future,
      builder: (context, s) {
        if (s.hasError) {
          return LoadError(retry: () => setState(() => future = load()));
        }
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        final data = s.data!,
            group = data['group'] as Map<String, dynamic>?,
            members = (data['members'] as List).cast<Map<String, dynamic>>();
        final uid = ref.read(messengerProvider).uid;
        final admin = members.any(
          (m) => m['user_id'] == uid && m['role'] == 'admin',
        );
        return ListView(
          children: [
            if (group != null) ...[
              ListTile(
                title: Text(
                  group['name'],
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                subtitle: Text(group['description']),
              ),
              if (admin) ...[
                ListTile(
                  title: const Text('Change group picture'),
                  onTap: () => act(context, () async {
                    final upload = await MediaService(
                      ref.read(supabaseProvider),
                    ).pick(widget.id, 'image');
                    if (upload != null) {
                      await manage(
                        'avatar',
                        value: upload.attachment['object_path'],
                      );
                    }
                  }),
                ),
                ListTile(
                  title: const Text('Edit group name'),
                  onTap: () => act(context, () async {
                    final v = await askText(
                      context,
                      'Group name',
                      initial: group['name'],
                    );
                    if (v != null) await manage('name', value: v);
                  }),
                ),
                ListTile(
                  title: const Text('Edit description'),
                  onTap: () => act(context, () async {
                    final v = await askText(
                      context,
                      'Description',
                      initial: group['description'],
                    );
                    if (v != null) await manage('description', value: v);
                  }),
                ),
                SwitchListTile(
                  title: const Text('Only admins can send messages'),
                  value: group['admin_only'],
                  onChanged: (v) => act(
                    context,
                    () => manage('admin_only', value: v.toString()),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.person_add_alt),
                  title: const Text('Invite member'),
                  onTap: () => act(context, () async {
                    final p = await context.push<Map<String, dynamic>>(
                      '/contacts?select=true',
                    );
                    if (p != null) await manage('invite', target: p['id']);
                  }),
                ),
              ],
            ],
            const ListTile(title: Text('Members')),
            for (final m in members)
              ListTile(
                leading: PersonAvatar(
                  name: m['profiles']['display_name'],
                  path: m['profiles']['avatar_path'],
                ),
                title: Text(m['profiles']['display_name']),
                subtitle: Text('@${m['profiles']['username']} · ${m['role']}'),
                trailing: admin && m['user_id'] != uid
                    ? PopupMenuButton<String>(
                        onSelected: (action) => act(
                          context,
                          () => manage(action, target: m['user_id']),
                        ),
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'promote',
                            child: Text('Make admin'),
                          ),
                          const PopupMenuItem(
                            value: 'remove',
                            child: Text('Remove member'),
                          ),
                        ],
                      )
                    : null,
                onTap: () => act(context, () async {
                  if (m['user_id'] == uid) return;
                  final p = m['profiles'];
                  await showModalBottomSheet<void>(
                    context: context,
                    builder: (c) => SafeArea(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ListTile(
                            title: Text(p['display_name']),
                            subtitle: SelectableText(
                              'Public ID: ${p['public_id']}\n${p['about']}',
                            ),
                          ),
                          ListTile(
                            title: const Text('Add contact'),
                            onTap: () {
                              Navigator.pop(c);
                              act(context, () async {
                                await ref
                                    .read(supabaseProvider)
                                    .from('contacts')
                                    .upsert({
                                      'owner_id': uid,
                                      'contact_id': p['id'],
                                    }, ignoreDuplicates: true);
                              });
                            },
                          ),
                          ListTile(
                            title: const Text('Block user'),
                            onTap: () {
                              Navigator.pop(c);
                              act(context, () async {
                                await ref
                                    .read(supabaseProvider)
                                    .from('user_blocks')
                                    .upsert({
                                      'blocker_id': uid,
                                      'blocked_id': p['id'],
                                    }, ignoreDuplicates: true);
                              });
                            },
                          ),
                          ListTile(
                            title: const Text('Report user'),
                            onTap: () {
                              Navigator.pop(c);
                              act(context, () async {
                                final reason = await askText(
                                  context,
                                  'Report reason (10+ characters)',
                                );
                                if (reason != null) {
                                  await ref
                                      .read(supabaseProvider)
                                      .from('user_reports')
                                      .insert({
                                        'reporter_id': uid,
                                        'reported_id': p['id'],
                                        'reason': reason,
                                      });
                                }
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ),
            if (group != null)
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Leave group'),
                onTap: () => act(context, () async {
                  await manage('leave');
                  if (context.mounted) context.go('/groups');
                }),
              ),
            if (group != null && admin)
              ListTile(
                leading: const Icon(Icons.delete_forever),
                title: const Text('Delete group'),
                onTap: () => act(context, () async {
                  final confirmation = await askText(
                    context,
                    'Type DELETE to delete this group',
                  );
                  if (confirmation == 'DELETE') {
                    await manage('delete');
                    if (context.mounted) context.go('/groups');
                  }
                }),
              ),
            const Divider(),
            const ListTile(title: Text('Shared media · recent 100')),
            for (final message in (data['media'] as List).map(
              (m) => ChatMessage.fromJson(m),
            ))
              if (message.attachment != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: AttachmentView(
                    client: ref.read(supabaseProvider),
                    attachment: message.attachment!,
                    kind: message.kind,
                    expiresAt: message.expiresAt,
                  ),
                ),
          ],
        );
      },
    ),
  );
}
