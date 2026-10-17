import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/security/local_retention.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/widgets/actions.dart';
import '../../core/widgets/private_scaffold.dart';
import '../../providers/app_providers.dart';
import 'message_yourself_tile.dart';

class ChatListScreen extends ConsumerStatefulWidget {
  const ChatListScreen({super.key});
  @override
  ConsumerState<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends ConsumerState<ChatListScreen> {
  late Stream<List<Map<String, dynamic>>> stream;
  Timer? expiryTimer;
  DateTime? expiryDeadline;
  void scheduleExpiration(List<Map<String, dynamic>> rows) {
    final times =
        rows
            .map((row) => DateTime.tryParse(row['preview_expires_at'] ?? ''))
            .whereType<DateTime>()
            .where((time) => time.isAfter(DateTime.now()))
            .toList()
          ..sort();
    final next = times.firstOrNull;
    if (next == expiryDeadline) return;
    expiryTimer?.cancel();
    expiryDeadline = next;
    if (next != null) {
      expiryTimer = Timer(
        next.difference(DateTime.now()) + const Duration(milliseconds: 20),
        () {
          expiryDeadline = null;
          if (mounted) setState(() {});
        },
      );
    }
  }

  @override
  void dispose() {
    expiryTimer?.cancel();
    super.dispose();
  }

  String query = '';
  bool archived = false;
  @override
  void initState() {
    super.initState();
    stream = ref.read(messengerProvider).conversations();
  }

  Future<void> update(Map<String, dynamic> c, String key) async {
    await ref
        .read(supabaseProvider)
        .from('conversation_members')
        .update({key: !(c[key] as bool)})
        .eq('conversation_id', c['id'])
        .eq('user_id', ref.read(messengerProvider).uid);
  }

  @override
  Widget build(BuildContext context) => PrivateScaffold(
    title: 'Your space',
    index: 0,
    actions: [
      IconButton(
        tooltip: archived ? 'Show chats' : 'Archived chats',
        onPressed: () => setState(() => archived = !archived),
        icon: Icon(
          archived ? Icons.unarchive_outlined : Icons.archive_outlined,
        ),
      ),
    ],
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => context.push('/contacts'),
      icon: const Icon(Icons.edit_outlined),
      label: const Text('New chat'),
    ),
    body: Column(
      children: [
        if (ref.read(messengerProvider).onlineOnly)
          ListTile(
            dense: true,
            leading: const Icon(Icons.lock_outline),
            title: const Text('Encrypted cache needs recovery'),
            subtitle: Text('Stage: ${ref.read(messengerProvider).cacheRecoveryStage ?? 'unknown'}. Chats use server data; existing encrypted drafts are preserved. New sends need a connection.'),
          ),
        const MessageYourselfTile(),
        Padding(
          padding: const EdgeInsets.all(16),
          child: SearchBar(
            hintText: 'Search your conversations',
            leading: const Icon(Icons.search),
            onChanged: (v) => setState(() => query = v.toLowerCase()),
          ),
        ),
        if (archived) const Text('Archived conversations'),
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: stream,
            builder: (context, s) {
              if (s.hasError && !s.hasData) {
                return LoadError(
                  retry: () => setState(
                    () => stream = ref.read(messengerProvider).conversations(),
                  ),
                );
              }
              if (!s.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              scheduleExpiration(s.data!);
              final rows = s.data!
                  .map((source) {
                    final row = Map<String, dynamic>.from(source);
                    if (recordExpired({
                      'expires_at': row['preview_expires_at'],
                    }, DateTime.now())) {
                      row['preview'] = null;
                      row['unread'] = 0;
                    }
                    return row;
                  })
                  .where(
                    (c) =>
                        c['archived'] == archived &&
                        (c['title'] as String).toLowerCase().contains(query),
                  )
                  .toList();
              if (rows.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'A little quiet here. Start a conversation with a username or public ID.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }
              return ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, _) =>
                    const Divider(indent: 80, height: 1),
                itemBuilder: (context, i) {
                  final c = rows[i];
                  return Dismissible(
                    key: ValueKey(c['id']),
                    confirmDismiss: (_) async {
                      await act(context, () => update(c, 'archived'));
                      return false;
                    },
                    background: Container(
                      color: Theme.of(context).colorScheme.secondaryContainer,
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.all(24),
                      child: const Icon(Icons.archive_outlined),
                    ),
                    child: ListTile(
                      leading: PersonAvatar(
                        name: c['title'],
                        path: c['avatar_path'],
                        bucket: c['kind'] == 'group' ? 'chat-media' : 'avatars',
                      ),
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              c['title'],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (c['pinned']) const Icon(Icons.push_pin, size: 14),
                          if (c['muted'])
                            const Icon(Icons.volume_off, size: 14),
                        ],
                      ),
                      subtitle: Text(
                        c['preview'] ?? 'Start the conversation',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            DateFormat.Hm().format(
                              DateTime.parse(c['updated_at']).toLocal(),
                            ),
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                          if ((c['unread'] as num) > 0)
                            Badge(label: Text('${c['unread']}')),
                        ],
                      ),
                      onTap: () => context.push('/chat/${c['id']}'),
                      onLongPress: () => showModalBottomSheet(
                        context: context,
                        builder: (context) => SafeArea(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final key in ['pinned', 'archived', 'muted'])
                                ListTile(
                                  title: Text(
                                    '${c[key] ? 'Disable' : 'Enable'} $key',
                                  ),
                                  onTap: () {
                                    Navigator.pop(context);
                                    act(this.context, () => update(c, key));
                                  },
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    ),
  );
}
