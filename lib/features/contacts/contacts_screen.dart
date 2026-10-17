import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/widgets/actions.dart';
import '../../core/widgets/private_scaffold.dart';
import '../../providers/app_providers.dart';
import '../chats/message_yourself_tile.dart';

class ContactsScreen extends ConsumerStatefulWidget {
  const ContactsScreen({super.key, this.selectOnly = false});
  final bool selectOnly;
  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends ConsumerState<ContactsScreen> {
  List<Map<String, dynamic>> users = [];
  Timer? debounce;
  bool loading = false;
  String? error;
  int generation = 0;
  Future<void> search(String value) async {
    final q = value.trim().toLowerCase();
    final version = ++generation;
    if (q.length < 3) {
      setState(() => users = []);
      return;
    }
    if (!RegExp(r'^[a-z0-9_\-]+$').hasMatch(q)) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final client = ref.read(supabaseProvider);
      var request = client
          .from('profiles')
          .select('id,public_id,username,display_name,avatar_path');
      request = RegExp(r'^[0-9a-f]{8}-[0-9a-f-]{27}$').hasMatch(q)
          ? request.eq('public_id', q)
          : request.ilike('username', '$q%');
      final rows = await request
          .neq('id', client.auth.currentUser!.id)
          .limit(30);
      if (mounted && version == generation) setState(() => users = rows);
    } catch (_) {
      if (mounted && version == generation) {
        setState(() => error = 'Search failed. Try again.');
      }
    } finally {
      if (mounted && version == generation) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.selectOnly ? 'Choose a person' : 'Find your people'),
    ),
    body: Column(
      children: [
        if (!widget.selectOnly) const MessageYourselfTile(replace: true),
        Padding(
          padding: const EdgeInsets.all(16),
          child: SearchBar(
            hintText: 'Username (3+ letters) or public ID',
            leading: const Icon(Icons.search),
            onChanged: (q) {
              debounce?.cancel();
              debounce = Timer(
                const Duration(milliseconds: 350),
                () => search(q),
              );
            },
          ),
        ),
        if (loading) const LinearProgressIndicator(),
        if (error != null) Text(error!),
        Expanded(
          child: users.isEmpty
              ? const Center(
                  child: Text(
                    'Search by username. Your address book stays on your device.',
                  ),
                )
              : ListView.builder(
                  itemCount: users.length,
                  itemBuilder: (context, i) {
                    final p = users[i];
                    return ListTile(
                      leading: PersonAvatar(
                        name: p['display_name'],
                        path: p['avatar_path'],
                      ),
                      title: Text(p['display_name']),
                      subtitle: Text('@${p['username']}'),
                      onTap: () => act(context, () async {
                        if (widget.selectOnly) {
                          context.pop(p);
                          return;
                        }
                        await ref
                            .read(supabaseProvider)
                            .from('contacts')
                            .upsert(
                              {
                                'owner_id': ref.read(messengerProvider).uid,
                                'contact_id': p['id'],
                              },
                              onConflict: 'owner_id,contact_id',
                              ignoreDuplicates: true,
                            );
                        final cid = await ref
                            .read(supabaseProvider)
                            .rpc('create_direct', params: {'peer': p['id']});
                        if (context.mounted) {
                          context.pushReplacement('/chat/$cid');
                        }
                      }),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}
