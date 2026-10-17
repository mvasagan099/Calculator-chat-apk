import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers/app_providers.dart';

class PrivateScaffold extends ConsumerWidget {
  const PrivateScaffold({
    super.key,
    required this.title,
    required this.index,
    required this.body,
    this.actions = const [],
    this.floatingActionButton,
  });
  final String title;
  final int index;
  final Widget body;
  final List<Widget> actions;
  final Widget? floatingActionButton;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      actions: [
        ...actions,
        IconButton(
          tooltip: 'Return to Calculator',
          onPressed: () => ref.read(lockProvider).lock(),
          icon: const Icon(Icons.calculate_outlined),
        ),
      ],
    ),
    body: body,
    floatingActionButton: floatingActionButton,
    bottomNavigationBar: NavigationBar(
      height: 72,
      animationDuration: const Duration(milliseconds: 230),
      selectedIndex: index,
      onDestinationSelected: (i) => context.go(
        ['/chats', '/updates', '/calls', '/groups', '/settings'][i],
      ),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.chat_bubble_outline),
          selectedIcon: Icon(Icons.chat_bubble),
          label: 'Chats',
        ),
        NavigationDestination(
          icon: Icon(Icons.auto_awesome_outlined),
          label: 'Updates',
        ),
        NavigationDestination(icon: Icon(Icons.call_outlined), label: 'Calls'),
        NavigationDestination(
          icon: Icon(Icons.groups_outlined),
          label: 'Groups',
        ),
        NavigationDestination(icon: Icon(Icons.tune), label: 'Settings'),
      ],
    ),
  );
}

class PersonAvatar extends ConsumerWidget {
  const PersonAvatar({
    super.key,
    required this.name,
    this.path,
    this.bucket = 'avatars',
  });
  final String name, bucket;
  final String? path;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fallback = Text(
      name.isEmpty ? '?' : name.characters.first.toUpperCase(),
    );
    if (path == null) return CircleAvatar(child: fallback);
    return FutureBuilder<String>(
      future: ref
          .read(supabaseProvider)
          .storage
          .from(bucket)
          .createSignedUrl(path!, 120),
      builder: (context, s) => CircleAvatar(
        backgroundImage: s.hasData ? NetworkImage(s.data!) : null,
        child: s.hasData ? null : fallback,
      ),
    );
  }
}
