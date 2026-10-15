import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'preview_fixtures.dart';
import 'preview_shell.dart';

class PreviewConversationScreen extends StatelessWidget {
  const PreviewConversationScreen({super.key, required this.conversation});
  final PreviewConversation conversation;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: () => context.push('/person/${conversation.id}'),
          child: Row(
            children: [
              PreviewAvatar(
                name: conversation.name,
                color: conversation.color,
                radius: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  conversation.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 19),
                ),
              ),
            ],
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            const PreviewNotice(),
            Expanded(
              child: Container(
                color: colors.surfaceContainerLowest,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Center(
                      child: Chip(
                        label: const Text('Sample conversation · Today'),
                        backgroundColor: colors.surfaceContainerHigh,
                      ),
                    ),
                    const SizedBox(height: 16),
                    for (final message in conversation.messages)
                      Align(
                        alignment: message.own
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          constraints: BoxConstraints(
                            maxWidth:
                                MediaQuery.sizeOf(context).width.clamp(0, 650) *
                                .8,
                          ),
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
                          decoration: BoxDecoration(
                            color: message.own
                                ? colors.primaryContainer
                                : colors.surfaceContainerHigh,
                            borderRadius: BorderRadius.only(
                              topLeft: const Radius.circular(20),
                              topRight: const Radius.circular(20),
                              bottomLeft: Radius.circular(message.own ? 20 : 4),
                              bottomRight: Radius.circular(
                                message.own ? 4 : 20,
                              ),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                message.text,
                                style: const TextStyle(
                                  fontSize: 16,
                                  height: 1.4,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '${message.time} · sample',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                enabled: false,
                decoration: InputDecoration(
                  hintText: 'Messaging connects in Phase 2',
                  prefixIcon: const Icon(Icons.add),
                  suffixIcon: Icon(Icons.send_outlined, color: colors.outline),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PreviewProfileScreen extends StatelessWidget {
  const PreviewProfileScreen({super.key, this.person});
  final PreviewConversation? person;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(person == null ? 'Your profile' : 'Preview profile'),
    ),
    body: Column(
      children: [
        const PreviewNotice(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Center(
                child: PreviewAvatar(
                  name: person?.name ?? 'Preview Owner',
                  color: person?.color ?? 0xff287d73,
                  radius: 52,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                person?.name ?? 'Preview Owner',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'Local development profile',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              const ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('About'),
                subtitle: Text(
                  'Finding joy in the everyday. Sample profile content.',
                ),
              ),
              const ListTile(
                leading: Icon(Icons.cloud_off_outlined),
                title: Text('Account'),
                subtitle: Text(
                  'Not registered. Authentication and public IDs connect in Phase 2.',
                ),
              ),
              if (person != null)
                FilledButton.icon(
                  onPressed: () => context.go('/chat/${person!.id}'),
                  icon: const Icon(Icons.chat_bubble_outline),
                  label: const Text('Open sample conversation'),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
