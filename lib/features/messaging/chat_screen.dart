import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import '../../core/widgets/actions.dart';
import '../../models/message.dart';
import '../../providers/app_providers.dart';
import '../media/media_service.dart';
import '../media/attachment_view.dart';
import 'conversation_presence.dart';
import 'structured_content.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final input = TextEditingController();
  final recorder = AudioRecorder();
  late Stream<List<ChatMessage>> messages;
  late ConversationPresence presence;
  List<ChatMessage> older = [];
  final selected = <String>{};
  ChatMessage? reply;
  bool uploading = false,
      recording = false,
      loadingOlder = false,
      hasOlder = true;
  String title = 'Conversation';
  String? lastSeen;
  bool direct = false, admin = false;
  int peerCount = 1;
  String? lastAck;
  double? uploadProgress;
  String search = '';
  List<ChatMessage>? searchResults;
  StreamSubscription<Amplitude>? amplitude;
  final levels = <double>[];
  @override
  void initState() {
    super.initState();
    Future.microtask(_loadDetails);
    messages = ref.read(messengerProvider).messages(widget.id);
    presence = ConversationPresence(ref.read(supabaseProvider), widget.id);
  }

  Future<void> _loadDetails() async {
    try {
      final client = ref.read(supabaseProvider),
          uid = ref.read(messengerProvider).uid;
      final list = await client.rpc('conversation_list') as List;
      final row = list
          .cast<Map<String, dynamic>>()
          .where((r) => r['id'] == widget.id)
          .firstOrNull;
      final members = await client
          .from('conversation_members')
          .select('user_id,role')
          .eq('conversation_id', widget.id);
      String? seen;
      if (row?['peer_id'] != null) {
        final value = await client.rpc(
          'peer_presence',
          params: {'peer': row!['peer_id']},
        );
        if (value != null) {
          seen =
              'Last seen ${DateFormat.MMMd().add_Hm().format(DateTime.parse(value).toLocal())}';
        }
      }
      if (mounted) {
        setState(() {
          title = row?['title'] ?? 'Conversation';
          direct = row?['kind'] == 'direct';
          peerCount = (members.length - 1).clamp(1, 10000);
          admin = members.any(
            (m) => m['user_id'] == uid && m['role'] == 'admin',
          );
          lastSeen = seen;
        });
      }
    } catch (_) {
      /* Message fetching has its own retry UI. */
    }
  }

  @override
  void dispose() {
    input.dispose();
    amplitude?.cancel();
    recorder.cancel();
    recorder.dispose();
    presence.dispose();
    super.dispose();
  }

  Future<void> send() async {
    final body = input.text.trim();
    if (body.isEmpty) return;
    await ref.read(messengerProvider).send(widget.id, body, replyTo: reply?.id);
    if (mounted) {
      setState(() {
        input.clear();
        reply = null;
      });
    }
  }

  Future<void> attach(String source) async {
    if (uploading) return;
    setState(() => uploading = true);
    try {
      final upload = await MediaService(
        ref.read(supabaseProvider),
      ).pick(widget.id, source);
      if (upload != null) {
        await ref
            .read(messengerProvider)
            .send(
              widget.id,
              '',
              kind: upload.kind,
              attachment: upload.attachment,
              replyTo: reply?.id,
            );
      }
    } finally {
      if (mounted) setState(() => uploading = false);
    }
  }

  Future<void> voice() async {
    if (recording) {
      final path = await recorder.stop();
      await amplitude?.cancel();
      if (mounted) setState(() => recording = false);
      if (path == null) return;
      final file = File(path);
      if (mounted) setState(() => uploading = true);
      try {
        final upload = await MediaService(
          ref.read(supabaseProvider),
        ).upload(widget.id, file, forcedKind: 'voice');
        await ref
            .read(messengerProvider)
            .send(widget.id, '', kind: 'voice', attachment: upload.attachment);
      } finally {
        if (await file.exists()) await file.delete();
        if (mounted) setState(() => uploading = false);
      }
    } else {
      if (!await recorder.hasPermission()) {
        throw StateError('Microphone permission is required');
      }
      final dir = await getTemporaryDirectory();
      await recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: '${dir.path}/voice-${DateTime.now().millisecondsSinceEpoch}.m4a',
      );
      amplitude = recorder
          .onAmplitudeChanged(const Duration(milliseconds: 100))
          .listen((a) {
            if (mounted) {
              setState(() {
                levels.add(((a.current + 60) / 60).clamp(0.05, 1));
                if (levels.length > 40) levels.removeAt(0);
              });
            }
          });
      if (mounted) setState(() => recording = true);
    }
  }

  Future<void> location() async {
    final consent = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Share current location?'),
        content: const Text(
          'Only your current position will be sent to this conversation. No ongoing tracking.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Share'),
          ),
        ],
      ),
    );
    if (consent != true) return;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw StateError('Location permission is required');
    }
    final p = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 20),
      ),
    );
    await ref
        .read(messengerProvider)
        .send(
          widget.id,
          jsonEncode({'latitude': p.latitude, 'longitude': p.longitude}),
          kind: 'location',
        );
  }

  Future<void> mention() async {
    final members = await ref
        .read(supabaseProvider)
        .from('conversation_members')
        .select('profiles(id,username,display_name)')
        .eq('conversation_id', widget.id);
    if (!mounted) return;
    final name = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final member in members)
              ListTile(
                title: Text(member['profiles']['display_name']),
                subtitle: Text('@${member['profiles']['username']}'),
                onTap: () => Navigator.pop(c, member['profiles']['username']),
              ),
          ],
        ),
      ),
    );
    if (name != null) {
      input.text += ' @$name ';
      input.selection = TextSelection.collapsed(offset: input.text.length);
    }
  }

  Future<void> contact() async {
    final person = await context.push<Map<String, dynamic>>(
      '/contacts?select=true',
    );
    if (person == null) return;
    await ref
        .read(messengerProvider)
        .send(
          widget.id,
          jsonEncode({
            'id': person['id'],
            'name': person['display_name'],
            'username': person['username'],
          }),
          kind: 'contact',
        );
  }

  Future<void> forward(List<ChatMessage> rows) async {
    final conversations =
        await ref.read(supabaseProvider).rpc('conversation_list') as List;
    if (!mounted) return;
    final cid = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final row in conversations)
              ListTile(
                title: Text(row['title']),
                onTap: () => Navigator.pop(c, row['id']),
              ),
          ],
        ),
      ),
    );
    if (cid == null) return;
    // Forward media by copying through the authenticated Storage API, which
    // checks membership in both the source and destination conversations.
    for (final m in rows) {
      if (m.deleted) continue;
      if (m.attachment != null) {
        final client = ref.read(supabaseProvider);
        final a = m.attachment!;
        final bytes = await client.storage
            .from('chat-media')
            .download(a['object_path']);
        final dir = await getTemporaryDirectory();
        final name = (a['filename'] as String).replaceAll(
          RegExp(r'[^a-zA-Z0-9._-]'),
          '_',
        );
        final file = File('${dir.path}/forward-$name');
        await file.writeAsBytes(bytes);
        try {
          final upload = await MediaService(
            client,
          ).upload(cid, file, forcedKind: m.kind);
          await ref
              .read(messengerProvider)
              .send(
                cid,
                m.body,
                kind: m.kind,
                attachment: upload.attachment,
                forwarded: true,
              );
        } finally {
          if (await file.exists()) await file.delete();
        }
      } else {
        await ref
            .read(messengerProvider)
            .send(cid, m.body, kind: m.kind, forwarded: true);
      }
    }
    if (mounted) setState(() => selected.clear());
  }

  Future<void> actions(ChatMessage m) async {
    final own = m.senderId == ref.read(messengerProvider).uid;
    await showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final emoji in ['❤️', '👍', '😂', '😮', '🙏'])
                  TextButton(
                    onPressed: () {
                      Navigator.pop(c);
                      act(context, () async {
                        await ref
                            .read(supabaseProvider)
                            .rpc(
                              'react_message',
                              params: {'mid': m.id, 'reaction': emoji},
                            );
                      });
                    },
                    child: Text(emoji, style: const TextStyle(fontSize: 24)),
                  ),
              ],
            ),
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Reply'),
              onTap: () {
                Navigator.pop(c);
                setState(() => reply = m);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: m.body));
                Navigator.pop(c);
              },
            ),
            ListTile(
              leading: const Icon(Icons.check_circle_outline),
              title: const Text('Select'),
              onTap: () {
                Navigator.pop(c);
                setState(() => selected.add(m.id));
              },
            ),
            ListTile(
              leading: const Icon(Icons.forward),
              title: const Text('Forward'),
              onTap: () {
                Navigator.pop(c);
                act(context, () => forward([m]));
              },
            ),
            if (own &&
                m.kind == 'text' &&
                DateTime.now().difference(m.createdAt) <
                    const Duration(minutes: 15))
              ListTile(
                title: const Text('Edit (15-minute limit)'),
                onTap: () {
                  Navigator.pop(c);
                  act(context, () async {
                    final text = await askText(
                      context,
                      'Edit message',
                      initial: m.body,
                    );
                    if (text != null) {
                      await ref
                          .read(supabaseProvider)
                          .rpc(
                            'edit_message',
                            params: {'mid': m.id, 'content': text},
                          );
                    }
                  });
                },
              ),
            ListTile(
              title: const Text('Delete for me'),
              onTap: () {
                Navigator.pop(c);
                act(context, () => ref.read(messengerProvider).hide(m.id));
              },
            ),
            if (admin ||
                (own &&
                    DateTime.now().difference(m.createdAt) <
                        const Duration(hours: 24)))
              ListTile(
                title: const Text('Delete for everyone (24-hour limit)'),
                onTap: () {
                  Navigator.pop(c);
                  act(context, () async {
                    await ref
                        .read(supabaseProvider)
                        .rpc('delete_message', params: {'mid': m.id});
                  });
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget bubble(ChatMessage m) {
    final own = m.senderId == ref.read(messengerProvider).uid;
    final colors = Theme.of(context).colorScheme;
    final read =
            m.receipts.where((r) => r['read_at'] != null).length >= peerCount,
        delivered = m.receipts.length >= peerCount;
    return GestureDetector(
      onLongPress: m.deleted
          ? null
          : m.pending
          ? () => showModalBottomSheet<void>(
              context: context,
              builder: (c) => SafeArea(
                child: ListTile(
                  title: const Text('Discard unsent message'),
                  onTap: () {
                    Navigator.pop(c);
                    act(
                      context,
                      () => ref.read(messengerProvider).discardPending(m.id),
                    );
                  },
                ),
              ),
            )
          : () => actions(m),
      onTap: selected.isEmpty
          ? null
          : () => setState(
              () => selected.contains(m.id)
                  ? selected.remove(m.id)
                  : selected.add(m.id),
            ),
      child: Container(
        color: selected.contains(m.id)
            ? colors.secondaryContainer.withValues(alpha: 0.4)
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: Align(
          alignment: own ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * .82,
            ),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: own
                    ? colors.primaryContainer
                    : colors.surfaceContainerHighest,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18),
                  topRight: const Radius.circular(18),
                  bottomLeft: Radius.circular(own ? 18 : 4),
                  bottomRight: Radius.circular(own ? 4 : 18),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!own && !direct)
                    Text(
                      m.senderName ?? 'Member',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  if (m.forwarded)
                    Text(
                      'Forwarded',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  if (m.replyTo != null)
                    Container(
                      padding: const EdgeInsets.all(8),
                      margin: const EdgeInsets.only(bottom: 6),
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(color: colors.primary, width: 3),
                        ),
                      ),
                      child: const Text('↩ Reply to a message'),
                    ),
                  if (m.deleted)
                    const Text(
                      'Message deleted',
                      style: TextStyle(fontStyle: FontStyle.italic),
                    )
                  else ...[
                    if (m.attachment != null)
                      AttachmentView(
                        key: ValueKey(m.id),
                        client: ref.read(supabaseProvider),
                        attachment: m.attachment!,
                        kind: m.kind,
                      ),
                    if (m.body.isNotEmpty)
                      if (m.kind == 'contact' || m.kind == 'location')
                        StructuredContent(message: m)
                      else
                        Text(m.body),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${m.edited ? 'edited · ' : ''}${DateFormat.Hm().format(m.createdAt.toLocal())}',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      if (own) ...[
                        const SizedBox(width: 4),
                        if (m.failed)
                          InkWell(
                            onTap: () => ref
                                .read(messengerProvider)
                                .flush(includeTerminal: true),
                            child: const Icon(Icons.refresh, size: 16),
                          )
                        else
                          Icon(
                            m.pending
                                ? Icons.schedule
                                : delivered
                                ? Icons.done_all
                                : Icons.done,
                            size: 16,
                            color: read ? colors.primary : null,
                          ),
                      ],
                    ],
                  ),
                  if (m.reactions.isNotEmpty)
                    Wrap(
                      children: [
                        for (final emoji
                            in m.reactions.map((e) => e['emoji']).toSet())
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Text(
                              '$emoji ${m.reactions.where((e) => e['emoji'] == emoji).length}',
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: ListenableBuilder(
        listenable: presence,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              presence.typing
                  ? 'Typing…'
                  : presence.online
                  ? 'Online'
                  : lastSeen ?? 'Private space',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
      actions: [
        IconButton(
          tooltip: 'Search messages',
          icon: const Icon(Icons.search),
          onPressed: () => act(context, () async {
            final q = await askText(context, 'Search messages');
            if (q == null) return;
            if (q.trim().isEmpty) {
              setState(() => searchResults = null);
              return;
            }
            final rows = await ref
                .read(supabaseProvider)
                .from('messages')
                .select(
                  '*,message_attachments(*),message_reactions(*),message_receipts(*)',
                )
                .eq('conversation_id', widget.id)
                .isFilter('deleted_at', null)
                .ilike('body', '%${q.trim()}%')
                .order('created_at', ascending: false)
                .limit(50);
            if (mounted) {
              setState(
                () => searchResults = rows.map(ChatMessage.fromJson).toList(),
              );
            }
          }),
        ),
        if (direct)
          for (final video in [false, true])
            IconButton(
              tooltip: video ? 'Video call' : 'Voice call',
              icon: Icon(video ? Icons.videocam_outlined : Icons.call_outlined),
              onPressed: () => act(context, () async {
                final id = await ref
                    .read(supabaseProvider)
                    .rpc(
                      'start_call',
                      params: {'cid': widget.id, 'use_video': video},
                    );
                if (context.mounted) context.push('/call/$id');
              }),
            ),
        IconButton(
          tooltip: 'Details and members',
          onPressed: () => context.push('/details/${widget.id}'),
          icon: const Icon(Icons.more_vert),
        ),
      ],
    ),
    body: Column(
      children: [
        if (uploading) LinearProgressIndicator(value: uploadProgress),
        if (searchResults != null)
          ListTile(
            title: Text('${searchResults!.length} search results (up to 50)'),
            trailing: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => setState(() => searchResults = null),
            ),
          ),
        Expanded(
          child: StreamBuilder<List<ChatMessage>>(
            stream: messages,
            builder: (context, s) {
              final merged = {
                for (final m in older) m.id: m,
                for (final m in s.data ?? <ChatMessage>[]) m.id: m,
              };
              final rows =
                  searchResults ??
                  (merged.values
                      .where((m) => !ref.read(messengerProvider).isHidden(m.id))
                      .toList()
                    ..sort((a, b) => b.createdAt.compareTo(a.createdAt)));
              if (s.hasError && rows.isEmpty) {
                return LoadError(
                  retry: () => setState(
                    () => messages = ref
                        .read(messengerProvider)
                        .messages(widget.id),
                  ),
                );
              }
              if (!s.hasData && rows.isEmpty) {
                return const Center(child: CircularProgressIndicator());
              }
              final incoming = rows
                  .where((m) => m.senderId != ref.read(messengerProvider).uid)
                  .firstOrNull;
              if (incoming != null && lastAck != incoming.id) {
                lastAck = incoming.id;
                unawaited(
                  ref
                      .read(supabaseProvider)
                      .rpc(
                        'ack_messages',
                        params: {'cid': widget.id, 'mark_read': true},
                      )
                      .catchError((Object _) {}),
                );
              }
              return Column(
                children: [
                  if (s.hasError)
                    const Text('Offline · showing previously loaded messages'),
                  if (selected.isNotEmpty)
                    Row(
                      children: [
                        TextButton(
                          onPressed: () => setState(() => selected.clear()),
                          child: Text('${selected.length} selected · clear'),
                        ),
                        IconButton(
                          tooltip: 'Forward selected',
                          onPressed: () => act(
                            context,
                            () => forward(
                              rows
                                  .where((m) => selected.contains(m.id))
                                  .toList(),
                            ),
                          ),
                          icon: const Icon(Icons.forward),
                        ),
                        IconButton(
                          tooltip: 'Delete selected for me',
                          onPressed: () => act(context, () async {
                            for (final id in selected) {
                              await ref.read(messengerProvider).hide(id);
                            }
                            if (mounted) setState(() => selected.clear());
                          }),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                  Expanded(
                    child: rows.isEmpty
                        ? const Center(
                            child: Text(
                              'Say hello. Messages appear here as they arrive.',
                            ),
                          )
                        : ListView.builder(
                            reverse: true,
                            itemCount: rows.length + 1,
                            itemBuilder: (context, i) {
                              if (i == rows.length) {
                                return hasOlder && searchResults == null
                                    ? TextButton(
                                        onPressed: loadingOlder
                                            ? null
                                            : () => act(context, () async {
                                                setState(
                                                  () => loadingOlder = true,
                                                );
                                                try {
                                                  final last = rows.last;
                                                  final page = await ref
                                                      .read(messengerProvider)
                                                      .page(
                                                        widget.id,
                                                        before: {
                                                          'id': last.id,
                                                          'created_at': last
                                                              .createdAt
                                                              .toUtc()
                                                              .toIso8601String(),
                                                        },
                                                      );
                                                  if (mounted) {
                                                    setState(() {
                                                      older.addAll(
                                                        page.map(
                                                          ChatMessage.fromJson,
                                                        ),
                                                      );
                                                      hasOlder =
                                                          page.length == 50;
                                                    });
                                                  }
                                                } finally {
                                                  if (mounted) {
                                                    setState(
                                                      () =>
                                                          loadingOlder = false,
                                                    );
                                                  }
                                                }
                                              }),
                                        child: Text(
                                          loadingOlder
                                              ? 'Loading…'
                                              : 'Load earlier messages',
                                        ),
                                      )
                                    : const SizedBox.shrink();
                              }
                              final m = rows[i];
                              final showDate =
                                  i == rows.length - 1 ||
                                  DateUtils.dateOnly(m.createdAt.toLocal()) !=
                                      DateUtils.dateOnly(
                                        rows[i + 1].createdAt.toLocal(),
                                      );
                              return Column(
                                children: [
                                  if (showDate)
                                    Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Text(
                                        DateFormat.yMMMd().format(
                                          m.createdAt.toLocal(),
                                        ),
                                        style: Theme.of(
                                          context,
                                        ).textTheme.labelSmall,
                                      ),
                                    ),
                                  bubble(m),
                                ],
                              );
                            },
                          ),
                  ),
                ],
              );
            },
          ),
        ),
        if (reply != null)
          ListTile(
            dense: true,
            title: const Text('Replying to message'),
            subtitle: Text(reply!.body, maxLines: 1),
            trailing: IconButton(
              onPressed: () => setState(() => reply = null),
              icon: const Icon(Icons.close),
            ),
          ),
        if (recording)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Icon(Icons.mic, color: Colors.red),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 30,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        for (final n in levels)
                          Container(
                            width: 3,
                            height: n * 30,
                            margin: const EdgeInsets.symmetric(horizontal: 1),
                            color: Theme.of(context).colorScheme.primary,
                          ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Discard recording',
                  onPressed: () async {
                    await recorder.cancel();
                    await amplitude?.cancel();
                    if (mounted) setState(() => recording = false);
                  },
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                PopupMenuButton<String>(
                  tooltip: 'Attach',
                  icon: const Icon(Icons.add_circle_outline),
                  onSelected: (value) => act(
                    context,
                    () => value == 'location'
                        ? location()
                        : value == 'mention'
                        ? mention()
                        : value == 'contact'
                        ? contact()
                        : attach(value),
                  ),
                  itemBuilder: (_) => [
                    for (final item in {
                      'image': 'Image',
                      'camera': 'Camera',
                      'video': 'Video',
                      'file': 'File or audio',
                      'contact': 'Contact card',
                      'location': 'Current location',
                      'mention': 'Mention member',
                    }.entries)
                      PopupMenuItem(value: item.key, child: Text(item.value)),
                  ],
                ),
                Expanded(
                  child: TextField(
                    controller: input,
                    minLines: 1,
                    maxLines: 5,
                    maxLength: 16000,
                    decoration: InputDecoration(
                      hintText: 'Message',
                      counterText: '',
                      filled: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: (_) {
                      ref.read(lockProvider).touch();
                      presence.sendTyping();
                    },
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: recording
                      ? 'Send recording'
                      : 'Record voice message',
                  onPressed: uploading ? null : () => act(context, voice),
                  icon: Icon(recording ? Icons.stop : Icons.mic_none),
                ),
                IconButton.filled(
                  tooltip: 'Send message',
                  onPressed: () => act(context, send),
                  icon: const Icon(Icons.arrow_upward),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
