import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/widgets/actions.dart';
import '../../core/widgets/private_scaffold.dart';
import '../../providers/app_providers.dart';
import '../../models/message.dart';
import '../media/attachment_view.dart';
import '../media/media_service.dart';
import '../../core/services/private_media_access.dart';
import 'group_audit_log_sheet.dart';

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
        final isOwner = group != null && (group['owner_id'] == uid ||
            members.any((m) => m['user_id'] == uid && m['role'] == 'owner'));
        final admin = isOwner || members.any(
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
                subtitle: Text(group['description'] ?? ''),
              ),
              if (admin) ...[
                ListTile(
                  leading: const Icon(Icons.photo_camera_outlined),
                  title: const Text('Change group picture'),
                  onTap: () => act(context, () async {
                    final access = PrivateMediaAccess(ref.read(lockProvider),
                        ref.read(authServiceProvider), ref.read(supabaseProvider), isCurrent: () => mounted);
                    final upload = await MediaService(
                      ref.read(supabaseProvider),
                      access: access,
                    ).pick(widget.id, 'image', groupIcon: true);
                    if (upload != null && mounted) {
                      access.check();
                      await manage(
                        'avatar',
                        value: upload.attachment['object_path'],
                      );
                    }
                  }),
                ),
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
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
                  leading: const Icon(Icons.description_outlined),
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
                  value: group['members_can_send'] == false || group['admin_only'] == true,
                  onChanged: (v) => act(
                    context,
                    () => manage('admin_only', value: v.toString()),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: const Text('Slow mode'),
                  subtitle: Text(
                    (group['slow_mode_seconds'] as num? ?? 0) == 0
                        ? 'Off'
                        : '${group['slow_mode_seconds']}s message cooldown',
                  ),
                  onTap: () async {
                    final selected = await showDialog<int>(
                      context: context,
                      builder: (ctx) => SimpleDialog(
                        title: const Text('Set message slow mode'),
                        children: [
                          for (final seconds in [0, 10, 30, 60, 300, 900])
                            SimpleDialogOption(
                              onPressed: () => Navigator.pop(ctx, seconds),
                              child: Text(seconds == 0 ? 'Off' : '${seconds}s'),
                            ),
                        ],
                      ),
                    );
                    if (selected != null && mounted) {
                      await act(context, () => manage('slow_mode', value: selected.toString()));
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.admin_panel_settings_outlined),
                  title: const Text('Admin action history'),
                  subtitle: const Text('Audit log of group modifications'),
                  onTap: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    showDragHandle: true,
                    builder: (_) => GroupAuditLogSheet(conversationId: widget.id),
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
            const Divider(),
            const ListTile(title: Text('Members', style: TextStyle(fontWeight: FontWeight.bold))),
            for (final m in members)
              ListTile(
                leading: PersonAvatar(
                  name: m['profiles']['display_name'],
                  path: m['profiles']['avatar_path'],
                ),
                title: Text(m['profiles']['display_name']),
                subtitle: Text(
                  '@${m['profiles']['username']} · ${m['role']}'
                  '${m['muted_until'] != null && DateTime.tryParse(m['muted_until'])?.isAfter(DateTime.now()) == true ? ' (muted)' : ''}',
                ),
                trailing: admin && m['user_id'] != uid
                    ? PopupMenuButton<String>(
                        onSelected: (action) => act(
                          context,
                          () async {
                            if (action == 'mute_1h') {
                              await manage('mute', target: m['user_id'], value: '60');
                            } else if (action == 'mute_24h') {
                              await manage('mute', target: m['user_id'], value: '1440');
                            } else if (action == 'unmute') {
                              await manage('unmute', target: m['user_id']);
                            } else {
                              await manage(action, target: m['user_id']);
                            }
                          },
                        ),
                        itemBuilder: (_) => [
                          if (m['role'] != 'admin' && m['role'] != 'owner')
                            const PopupMenuItem(
                              value: 'promote',
                              child: Text('Make admin'),
                            ),
                          if (isOwner && m['role'] == 'admin')
                            const PopupMenuItem(
                              value: 'demote',
                              child: Text('Dismiss as admin'),
                            ),
                          if (isOwner && m['user_id'] != uid)
                            const PopupMenuItem(
                              value: 'transfer_ownership',
                              child: Text('Transfer ownership'),
                            ),
                          if (m['muted_until'] != null && DateTime.tryParse(m['muted_until'])?.isAfter(DateTime.now()) == true)
                            const PopupMenuItem(
                              value: 'unmute',
                              child: Text('Unmute member'),
                            )
                          else ...[
                            const PopupMenuItem(
                              value: 'mute_1h',
                              child: Text('Mute for 1 hour'),
                            ),
                            const PopupMenuItem(
                              value: 'mute_24h',
                              child: Text('Mute for 24 hours'),
                            ),
                          ],
                          const PopupMenuItem(
                            value: 'remove',
                            child: Text('Remove from group'),
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
