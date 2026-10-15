import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'preview_fixtures.dart';
import 'preview_shell.dart';

class PreviewChatsScreen extends StatefulWidget {
  const PreviewChatsScreen({
    super.key,
    this.selecting = false,
    this.groups = false,
  });
  final bool selecting, groups;
  @override
  State<PreviewChatsScreen> createState() => _PreviewChatsScreenState();
}

class _PreviewChatsScreenState extends State<PreviewChatsScreen> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final chats = previewConversations
        .where(
          (chat) =>
              (!widget.groups || chat.group) &&
              chat.name.toLowerCase().contains(query.toLowerCase()),
        )
        .toList();
    return PreviewShell(
      title: widget.selecting
          ? 'Choose a preview'
          : widget.groups
          ? 'Groups'
          : 'Your space',
      index: widget.groups ? 3 : 0,
      actions: [
        IconButton(
          tooltip: 'Your profile',
          onPressed: () => context.push('/profile'),
          icon: const Icon(Icons.account_circle_outlined),
        ),
      ],
      floatingActionButton: widget.selecting
          ? null
          : FloatingActionButton.extended(
              onPressed: () => context.push('/contacts'),
              icon: const Icon(Icons.edit_square),
              label: const Text('New chat'),
            ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              onChanged: (value) => setState(() => query = value),
              decoration: const InputDecoration(
                hintText: 'Search sample conversations',
                prefixIcon: Icon(Icons.search),
                border: InputBorder.none,
              ),
            ),
          ),
          Expanded(
            child: chats.isEmpty
                ? const Center(
                    child: Text('No sample conversations match your search.'),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 90),
                    itemCount: chats.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, indent: 88),
                    itemBuilder: (context, index) {
                      final chat = chats[index];
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 8,
                        ),
                        leading: PreviewAvatar(
                          name: chat.name,
                          color: chat.color,
                        ),
                        title: Text(
                          chat.name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Text(
                            chat.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              chat.messages.last.time,
                              style: TextStyle(
                                fontSize: 11,
                                color: chat.unread > 0
                                    ? colors.primary
                                    : colors.onSurfaceVariant,
                              ),
                            ),
                            if (chat.unread > 0) ...[
                              const SizedBox(height: 5),
                              Badge(
                                label: Text('${chat.unread}'),
                                backgroundColor: colors.primary,
                              ),
                            ],
                          ],
                        ),
                        onTap: () => context.push('/chat/${chat.id}'),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class PreviewUpdatesScreen extends StatelessWidget {
  const PreviewUpdatesScreen({super.key});
  @override
  Widget build(BuildContext context) => PreviewShell(
    title: 'Updates',
    index: 1,
    child: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Small moments, shared',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        const Text(
          'Local status layouts. Uploads, visibility and 24-hour expiry connect in Phase 2.',
        ),
        const SizedBox(height: 24),
        for (final chat in previewConversations.where((chat) => !chat.group))
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              leading: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  ),
                ),
                child: PreviewAvatar(name: chat.name, color: chat.color),
              ),
              title: Text(chat.name),
              subtitle: const Text('Sample text status'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/status/${chat.id}'),
            ),
          ),
      ],
    ),
  );
}

class PreviewStatusScreen extends StatelessWidget {
  const PreviewStatusScreen({super.key, required this.conversation});
  final PreviewConversation conversation;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(conversation.name)),
    body: Column(
      children: [
        const PreviewNotice(),
        Expanded(
          child: Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.tertiaryContainer,
            alignment: Alignment.center,
            padding: const EdgeInsets.all(32),
            child: Text(
              'A quiet morning. A fresh perspective. ☀️\n\nSample text status',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ),
        ),
      ],
    ),
  );
}

class PreviewCallsScreen extends StatelessWidget {
  const PreviewCallsScreen({super.key});
  @override
  Widget build(BuildContext context) => PreviewShell(
    title: 'Calls',
    index: 2,
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Card(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              'Call history layout preview. Calling is disabled in this local build. LiveKit setup and real-device validation are required for internet calls.',
            ),
          ),
        ),
        const SizedBox(height: 20),
        for (final chat in previewConversations.where((chat) => !chat.group))
          ListTile(
            leading: PreviewAvatar(name: chat.name, color: chat.color),
            title: Text(chat.name),
            subtitle: const Text('Sample outgoing call · Yesterday'),
            trailing: const Icon(Icons.call_outlined),
            onTap: () => context.push('/person/${chat.id}'),
          ),
      ],
    ),
  );
}
