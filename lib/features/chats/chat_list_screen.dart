import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/security/local_retention.dart';
import '../../core/widgets/actions.dart';
import '../../core/widgets/private_scaffold.dart';
import '../../providers/app_providers.dart';
import '../messaging/starred_messages_screen.dart';
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
  String query = '';
  String selectedFolder = 'All';

  void scheduleExpiration(List<Map<String, dynamic>> rows) {
    final times = rows
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

  Future<void> promptAddFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New chat folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'e.g. Work, Family, Friends',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      final settings = ref.read(deviceSettingsProvider);
      await settings?.addCustomFolder(name);
      setState(() => selectedFolder = name);
    }
  }

  Future<void> manageChatFolders(Map<String, dynamic> c) async {
    final settings = ref.read(deviceSettingsProvider);
    if (settings == null) return;
    final customFolders = settings.customFolders;
    if (customFolders.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No custom folders created yet. Tap "Add folder" above.')),
      );
      return;
    }
    final cid = c['id'] as String;
    final assigned = settings.getFoldersForChat(cid).toSet();

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('Folders for ${c['title']}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final folder in customFolders)
                CheckboxListTile(
                  title: Text(folder),
                  value: assigned.contains(folder),
                  onChanged: (val) async {
                    if (val == true) {
                      assigned.add(folder);
                    } else {
                      assigned.remove(folder);
                    }
                    await settings.setFoldersForChat(cid, assigned.toList());
                    setDialogState(() {});
                    if (mounted) setState(() {});
                  },
                ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  String _formatChatTimestamp(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return DateFormat.Hm().format(dt);
    }
    final yesterday = now.subtract(const Duration(days: 1));
    if (dt.year == yesterday.year && dt.month == yesterday.month && dt.day == yesterday.day) {
      return 'Yesterday';
    }
    if (now.difference(dt).inDays < 7) {
      return DateFormat.E().format(dt);
    }
    return DateFormat.MMMd().format(dt);
  }

  Widget _buildSkeletonLoading(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListView.separated(
      itemCount: 8,
      separatorBuilder: (_, _) => const Divider(indent: 76, height: 1),
      itemBuilder: (_, __) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest.withValues(alpha: 0.45),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 140,
                    height: 14,
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHighest.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(7),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    height: 12,
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHighest.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Container(
              width: 36,
              height: 12,
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, String folder) {
    final colors = Theme.of(context).colorScheme;
    final (icon, headline, message) = switch (folder) {
      'Archived' => (Icons.archive_outlined, 'No archived chats', 'Chats you archive will appear safely here.'),
      'Unread' => (Icons.mark_chat_read_outlined, 'No unread messages', 'You are completely caught up!'),
      'Groups' => (Icons.groups_outlined, 'No group conversations', 'Create or join a group to start collaborating.'),
      'Direct' => (Icons.person_outline, 'No direct messages', 'Start a secure one-on-one private chat.'),
      _ => (Icons.chat_bubble_outline_rounded, 'No conversations yet', 'Your private chats are protected by your secret calculator PIN.'),
    };

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: colors.primaryContainer.withValues(alpha: 0.4),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 36, color: colors.primary),
            ),
            const SizedBox(height: 18),
            Text(headline, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 14),
            ),
            const SizedBox(height: 22),
            if (folder == 'All')
              FilledButton.tonalIcon(
                onPressed: () => context.push('/contacts'),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Start a conversation'),
              ),
          ],
        ),
      ),
    );
  }

  void _showChatOptions(Map<String, dynamic> c) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(c['pinned'] == true ? Icons.push_pin_outlined : Icons.push_pin),
              title: Text(c['pinned'] == true ? 'Unpin chat' : 'Pin chat to top'),
              onTap: () {
                Navigator.pop(sheetContext);
                act(context, () => update(c, 'pinned'));
              },
            ),
            ListTile(
              leading: Icon(c['archived'] == true ? Icons.unarchive : Icons.archive),
              title: Text(c['archived'] == true ? 'Unarchive chat' : 'Archive chat'),
              onTap: () {
                Navigator.pop(sheetContext);
                act(context, () => update(c, 'archived'));
              },
            ),
            ListTile(
              leading: Icon(c['muted'] == true ? Icons.volume_up : Icons.volume_off),
              title: Text(c['muted'] == true ? 'Unmute chat' : 'Mute notifications'),
              onTap: () {
                Navigator.pop(sheetContext);
                act(context, () => update(c, 'muted'));
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('Manage folders...'),
              onTap: () {
                Navigator.pop(sheetContext);
                manageChatFolders(c);
              },
            ),
            ListTile(
              leading: const Icon(Icons.star_outline),
              title: const Text('Starred messages'),
              onTap: () {
                Navigator.pop(sheetContext);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => StarredMessagesScreen(conversationId: c['id']),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConversationTile(BuildContext context, Map<String, dynamic> c) {
    final colors = Theme.of(context).colorScheme;
    final isPinned = c['pinned'] == true;
    final unreadCount = (c['unread'] as num? ?? 0).toInt();

    return Dismissible(
      key: ValueKey(c['id']),
      confirmDismiss: (_) async {
        await act(context, () => update(c, 'archived'));
        return false;
      },
      background: Container(
        color: colors.secondaryContainer,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.all(24),
        child: Icon(
          c['archived'] == true ? Icons.unarchive_outlined : Icons.archive_outlined,
          color: colors.onSecondaryContainer,
        ),
      ),
      child: InkWell(
        onTap: () => context.push('/chat/${c['id']}'),
        onLongPress: () => _showChatOptions(c),
        child: Container(
          color: isPinned ? colors.primary.withValues(alpha: 0.04) : null,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              PersonAvatar(
                name: c['title'] as String? ?? 'Chat',
                path: c['avatar_path'] as String?,
                bucket: c['kind'] == 'group' ? 'chat-media' : 'avatars',
                radius: 25,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (c['kind'] == 'group') ...[
                          Icon(Icons.groups_rounded, size: 16, color: colors.primary),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: Text(
                            c['title'] as String? ?? 'Conversation',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: unreadCount > 0 ? FontWeight.w700 : FontWeight.w600,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _formatChatTimestamp(c['updated_at'] as String?),
                          style: TextStyle(
                            fontSize: 12,
                            color: unreadCount > 0 ? colors.primary : colors.onSurfaceVariant,
                            fontWeight: unreadCount > 0 ? FontWeight.w600 : FontWeight.w400,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            c['preview'] as String? ?? 'Start the conversation',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: unreadCount > 0 ? colors.onSurface : colors.onSurfaceVariant,
                              fontWeight: unreadCount > 0 ? FontWeight.w500 : FontWeight.w400,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        if (c['muted'] == true) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.volume_off_rounded, size: 15, color: colors.outline),
                        ],
                        if (isPinned) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.push_pin_rounded, size: 15, color: colors.primary),
                        ],
                        if (unreadCount > 0) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: colors.primary,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '$unreadCount',
                              style: TextStyle(
                                color: colors.onPrimary,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(deviceSettingsProvider);
    final customFolders = settings?.customFolders ?? [];
    final folders = ['All', 'Unread', 'Direct', 'Groups', 'Archived', ...customFolders];

    return PrivateScaffold(
      title: 'Your space',
      index: 0,
      actions: [
        IconButton(
          tooltip: 'All starred messages',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const StarredMessagesScreen()),
          ),
          icon: const Icon(Icons.star_outline),
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
              subtitle: Text(
                'Stage: ${ref.read(messengerProvider).cacheRecoveryStage ?? 'unknown'}. Chats use server data; existing encrypted drafts are preserved. New sends need a connection.',
              ),
            ),
          const MessageYourselfTile(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: SearchBar(
              hintText: 'Search your conversations',
              leading: const Icon(Icons.search),
              elevation: const WidgetStatePropertyAll(0),
              backgroundColor: WidgetStatePropertyAll(
                Theme.of(context).colorScheme.surfaceContainerLow,
              ),
              onChanged: (v) => setState(() => query = v.toLowerCase()),
            ),
          ),
          // Chat Folders Filter Bar
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                for (final folder in folders)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      avatar: folder == 'Archived'
                          ? const Icon(Icons.archive_outlined, size: 16)
                          : folder == 'Unread'
                          ? const Icon(Icons.mark_chat_unread_outlined, size: 16)
                          : null,
                      label: Text(folder),
                      selected: selectedFolder == folder,
                      onSelected: (selected) {
                        if (selected) setState(() => selectedFolder = folder);
                      },
                    ),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.add, size: 16),
                  label: const Text('Add folder'),
                  onPressed: promptAddFolder,
                ),
              ],
            ),
          ),
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
                  return _buildSkeletonLoading(context);
                }
                scheduleExpiration(s.data!);

                final isArchivedFolder = selectedFolder == 'Archived';
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
                    .where((c) {
                      if (!(c['title'] as String).toLowerCase().contains(query)) {
                        return false;
                      }
                      final isArchived = c['archived'] == true;
                      if (isArchivedFolder) return isArchived;
                      if (isArchived) return false;

                      if (selectedFolder == 'All') return true;
                      if (selectedFolder == 'Unread') {
                        return (c['unread'] as num? ?? 0) > 0;
                      }
                      if (selectedFolder == 'Direct') return c['kind'] == 'direct';
                      if (selectedFolder == 'Groups') return c['kind'] == 'group';

                      final assigned = settings?.getFoldersForChat(c['id'] as String) ?? [];
                      return assigned.contains(selectedFolder);
                    })
                    .toList();

                // Sticky Pinned Chats: Pinned chats are sorted strictly to the top!
                rows.sort((a, b) {
                  final aPinned = a['pinned'] == true;
                  final bPinned = b['pinned'] == true;
                  if (aPinned != bPinned) return aPinned ? -1 : 1;
                  final aTime = DateTime.tryParse(a['updated_at'] ?? '') ?? DateTime(1970);
                  final bTime = DateTime.tryParse(b['updated_at'] ?? '') ?? DateTime(1970);
                  return bTime.compareTo(aTime);
                });

                if (rows.isEmpty) {
                  return RefreshIndicator(
                    onRefresh: () => ref.read(messengerProvider).sync(),
                    child: ListView(
                      children: [
                        SizedBox(
                          height: MediaQuery.of(context).size.height * 0.5,
                          child: _buildEmptyState(context, selectedFolder),
                        ),
                      ],
                    ),
                  );
                }

                return RefreshIndicator(
                  onRefresh: () => ref.read(messengerProvider).sync(),
                  child: ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const Divider(indent: 76, height: 1),
                    itemBuilder: (context, i) => _buildConversationTile(context, rows[i]),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
