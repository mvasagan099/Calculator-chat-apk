import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/services/auth_service.dart';
import '../../core/widgets/actions.dart';
import '../../providers/app_providers.dart';

class MessageYourselfTile extends ConsumerStatefulWidget {
  const MessageYourselfTile({super.key, this.replace = false});
  final bool replace;
  @override
  ConsumerState<MessageYourselfTile> createState() => _MessageYourselfTileState();
}

class _MessageYourselfTileState extends ConsumerState<MessageYourselfTile> {
  bool busy = false;
  Future<void> open() async {
    if (busy) return;
    final client = ref.read(supabaseProvider);
    final auth = ref.read(authServiceProvider);
    final lock = ref.read(lockProvider);
    final owner = client.auth.currentUser?.id;
    final session = AuthService.tokenSession(client.auth.currentSession);
    final epoch = lock.securityEpoch;
    bool current() => mounted && owner != null && session != null &&
      auth?.signedIn == true && auth?.ownerMatches == true && auth?.deviceAuthorized == true &&
      client.auth.currentUser?.id == owner && AuthService.tokenSession(client.auth.currentSession) == session &&
      lock.privateActionValid(epoch);
    if (!current()) throw StateError('Unlock your approved session first');
    setState(() => busy = true);
    try {
      final cid = await client.rpc('create_direct', params: {'peer': owner}) as String;
      if (!mounted || !current()) return;
      if (widget.replace) {
        context.pushReplacement('/chat/$cid');
      } else {
        context.push('/chat/$cid');
      }
    } finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) => ListTile(
    leading: const CircleAvatar(child: Icon(Icons.bookmark_outline)),
    title: const Text('Message Yourself'),
    subtitle: const Text('Private notes and files'),
    enabled: !busy,
    onTap: () => act(context, open),
  );
}
