import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/widgets/actions.dart';
import '../../core/widgets/private_scaffold.dart';
import '../../models/message.dart';
import '../../providers/app_providers.dart';

class StarredMessagesScreen extends ConsumerStatefulWidget {
  const StarredMessagesScreen({super.key, this.conversationId});
  final String? conversationId;

  @override
  ConsumerState<StarredMessagesScreen> createState() => _StarredMessagesScreenState();
}

class _StarredMessagesScreenState extends ConsumerState<StarredMessagesScreen> {
  String query = '';

  @override
  Widget build(BuildContext context) {
    final messenger = ref.watch(messengerProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.conversationId != null ? 'Starred messages' : 'All starred messages'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SearchBar(
              hintText: 'Search starred messages...',
              leading: const Icon(Icons.search),
              onChanged: (v) => setState(() => query = v.toLowerCase()),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: messenger.getStarredMessages(conversationId: widget.conversationId),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final rawList = snapshot.data ?? [];
                final filtered = rawList.where((item) {
                  final msg = item['messages'] is Map ? item['messages'] as Map : item;
                  final body = (msg['body'] as String? ?? '').toLowerCase();
                  return body.contains(query);
                }).toList();

                if (filtered.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.star_outline, size: 64, color: Theme.of(context).hintColor),
                          const SizedBox(height: 16),
                          Text(
                            query.isEmpty
                                ? 'No starred messages yet.\nLong-press any message and tap Star to save it here.'
                                : 'No matching starred messages.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final item = filtered[i];
                    final msgMap = item['messages'] is Map ? item['messages'] as Map<String, dynamic> : item;
                    final mid = item['message_id'] as String? ?? msgMap['id'] as String? ?? '';
                    final cid = item['conversation_id'] as String? ?? msgMap['conversation_id'] as String? ?? '';
                    final senderProfile = msgMap['profiles'] as Map<String, dynamic>?;
                    final senderName = senderProfile?['display_name'] as String? ?? 'Sender';
                    final body = msgMap['body'] as String? ?? '';
                    final kind = msgMap['kind'] as String? ?? 'text';
                    final createdAt = DateTime.tryParse(msgMap['created_at'] ?? '')?.toLocal();

                    Widget contentWidget;
                    if (kind == 'poll') {
                      try {
                        final poll = jsonDecode(body) as Map;
                        contentWidget = Text('📊 Poll: ${poll['question']}');
                      } catch (_) {
                        contentWidget = const Text('📊 Poll');
                      }
                    } else if (kind == 'sticker') {
                      try {
                        final sticker = jsonDecode(body) as Map;
                        contentWidget = Row(
                          children: [
                            Text(sticker['emoji'] ?? '🏷️', style: const TextStyle(fontSize: 24)),
                            const SizedBox(width: 8),
                            Text('Sticker: ${sticker['title'] ?? ''}'),
                          ],
                        );
                      } catch (_) {
                        contentWidget = const Text('🏷️ Sticker');
                      }
                    } else if (kind == 'gif') {
                      contentWidget = const Row(
                        children: [
                          Icon(Icons.gif_box, size: 24),
                          SizedBox(width: 8),
                          Text('Animated GIF'),
                        ],
                      );
                    } else if (kind == 'image' || kind == 'video' || kind == 'audio') {
                      contentWidget = Row(
                        children: [
                          Icon(
                            kind == 'image' ? Icons.image : kind == 'video' ? Icons.videocam : Icons.audiotrack,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(body.isNotEmpty ? body : kind.toUpperCase()),
                        ],
                      );
                    } else {
                      contentWidget = Text(body, maxLines: 4, overflow: TextOverflow.ellipsis);
                    }

                    return ListTile(
                      leading: PersonAvatar(name: senderName),
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              senderName,
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                          if (createdAt != null)
                            Text(
                              DateFormat.yMMMd().add_jm().format(createdAt),
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                        ],
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: contentWidget,
                      ),
                      trailing: PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert, size: 20),
                        onSelected: (val) {
                          if (val == 'unstar') {
                            act(context, () async {
                              await messenger.unstarMessage(mid);
                              setState(() {});
                            });
                          } else if (val == 'copy') {
                            Clipboard.setData(ClipboardData(text: body));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Copied to clipboard')),
                            );
                          } else if (val == 'goto') {
                            if (cid.isNotEmpty) {
                              context.push('/chat/$cid');
                            }
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'goto',
                            child: Row(
                              children: [
                                Icon(Icons.open_in_new, size: 18),
                                SizedBox(width: 8),
                                Text('Go to message'),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'copy',
                            child: Row(
                              children: [
                                Icon(Icons.copy, size: 18),
                                SizedBox(width: 8),
                                Text('Copy text'),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'unstar',
                            child: Row(
                              children: [
                                Icon(Icons.star_border, size: 18),
                                SizedBox(width: 8),
                                Text('Unstar'),
                              ],
                            ),
                          ),
                        ],
                      ),
                      onTap: () {
                        if (cid.isNotEmpty) context.push('/chat/$cid');
                      },
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
}
