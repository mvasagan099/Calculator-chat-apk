import '../../core/security/private_media_files.dart';
import '../../core/security/local_retention.dart';
import '../../core/theme/app_theme.dart';
import '../calls/call_initiator.dart';
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
import 'chat_backdrop.dart';
import 'expiration_banner.dart';
import '../../core/services/private_media_access.dart';
import '../media/view_once_viewer.dart';

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
  String wallpaper = 'plain';
  bool sending = false, voiceBusy = false;
  String? lastSeen;
  bool direct = false, admin = false, selfChat = false, detailsLoaded = false;
  int peerCount = 1;
  String? lastAck;
  bool acknowledging = false;
  double? uploadProgress;
  String search = '';
  List<ChatMessage>? searchResults;
  StreamSubscription<Amplitude>? amplitude;
  final levels = <double>[];
  Timer? retentionTimer;
  DateTime? retentionDeadline;
  void scheduleRetention(List<ChatMessage> rows) {
    final times =
        rows
            .expand((m) => [m.expiresAt, if (m.attachment != null) attachmentDeadline(m.attachment!)])
            .whereType<DateTime>()
            .where((time) => time.isAfter(DateTime.now()))
            .toList()
          ..sort();
    final deadline = times.firstOrNull;
    if (deadline == retentionDeadline) return;
    retentionTimer?.cancel();
    retentionDeadline = deadline;
    if (deadline != null) {
      final repository = ref.read(messengerProvider);
      retentionTimer = Timer(
        deadline.difference(DateTime.now()) + const Duration(milliseconds: 20),
        () {
          retentionDeadline = null;
          if (mounted) {
            setState(() {
              if (reply?.expired == true) reply = null;
            });
            unawaited(repository.purgeExpiredLocal().catchError((Object _) {}));
          }
        },
      );
    }
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      if (!mounted) return;
      await _loadDetails();
      if (!mounted) return;
      final value = await ref.read(messengerProvider).wallpaper(widget.id);
      if (mounted) setState(() => wallpaper = value);
    });
    messages = ref
        .read(messengerProvider)
        .messages(widget.id, historyIds: () => older.map((m) => m.id));
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
          selfChat = row?['is_self'] == true;
          detailsLoaded = row != null;
          peerCount = selfChat ? 0 : (members.length - 1).clamp(1, 10000);
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
    retentionTimer?.cancel();
    input.dispose();
    amplitude?.cancel();
    recorder.cancel();
    recorder.dispose();
    presence.dispose();
    super.dispose();
  }

  Future<void> send() async {
    final body = input.text.trim();
    if (body.isEmpty || sending) return;
    final original = input.text;
    final replyingTo = reply;
    setState(() => sending = true);
    try {
      await ref
          .read(messengerProvider)
          .send(widget.id, body, replyTo: replyingTo?.id);
      if (mounted) {
        setState(() {
          // Preserve text typed while the encrypted outbox write was pending.
          if (input.text == original) input.clear();
          if (reply == replyingTo) reply = null;
        });
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> chooseWallpaper() async {
    final value = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('Chat wallpaper · this device')),
            for (final entry in {
              'plain': 'Plain',
              'linen': 'Linen',
              'dusk': 'Dusk',
            }.entries)
              ListTile(
                title: Text(entry.value),
                trailing: entry.key == wallpaper
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(c, entry.key),
              ),
          ],
        ),
      ),
    );
    if (value == null || !mounted) return;
    await ref.read(messengerProvider).setWallpaper(widget.id, value);
    if (mounted) setState(() => wallpaper = value);
  }

  Future<void> attach(String source) async {
    if (uploading) return;
    if (ref.read(messengerProvider).onlineOnly &&
        !['image', 'camera', 'video', 'image_once', 'video_once'].contains(source)) {
      throw StateError('Encrypted cache recovery is required before sending this file type.');
    }
    final access = PrivateMediaAccess(ref.read(lockProvider),
        ref.read(authServiceProvider), ref.read(supabaseProvider), isCurrent: () => mounted);
    access.check();
    setState(() => uploading = true);
    try {
      final upload = await MediaService(
        ref.read(supabaseProvider),
        access: access,
        onProgress: (value) {
          if (mounted) setState(() => uploadProgress = value);
        },
      ).pick(widget.id, source.replaceAll('_once', ''));
      if (upload != null && mounted) {
        access.check();
        await ref
            .read(messengerProvider)
            .send(
              widget.id,
              '',
              kind: upload.kind,
              attachment: upload.attachment,
              replyTo: source.endsWith('_once') ? null : reply?.id,
              viewOnce: source.endsWith('_once'),
            );
      }
    } finally {
      if (mounted) setState(() => uploading = false);
    }
  }

  Future<void> voice() async {
    if (voiceBusy) return;
    voiceBusy = true;
    try {
      await _voice();
    } finally {
      voiceBusy = false;
    }
  }

  Future<void> _voice() async {
    if (ref.read(messengerProvider).onlineOnly) {
      throw StateError('Encrypted cache recovery is required before sending voice recordings.');
    }
    if (recording) {
      final path = await recorder.stop();
      await amplitude?.cancel();
      if (mounted) setState(() => recording = false);
      if (path == null) return;
      final file = File(path);
      if (mounted) setState(() => uploading = true);
      try {
        if (!mounted) return;
        final upload = await MediaService(
          ref.read(supabaseProvider),
          onProgress: (value) {
            if (mounted) setState(() => uploadProgress = value);
          },
        ).upload(widget.id, file, forcedKind: 'voice');
        if (!mounted) return;
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
      if (!mounted) return;
      final dir = await getTemporaryDirectory();
      if (!mounted) return;
      await recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: '${dir.path}/voice-${DateTime.now().millisecondsSinceEpoch}.m4a',
      );
      if (!mounted) {
        await recorder.cancel();
        await recorder.dispose();
        return;
      }
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
    if (consent != true || !mounted) return;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (!mounted) return;
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
    if (!mounted) return;
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
    if (person == null || !mounted) return;
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
    if (cid == null || !mounted) return;
    // Forward media by copying through the authenticated Storage API, which
    // checks membership in both the source and destination conversations.
    for (final m in rows) {
      if (!mounted) return;
      if (m.viewOnce || m.expired || (['image', 'video'].contains(m.kind) && (m.attachment == null || visualAttachmentExpired(m.attachment!, DateTime.now())))) {
        throw StateError('This media cannot be forwarded');
      }
      if (m.deleted) continue;
      if (m.attachment != null) {
        final client = ref.read(supabaseProvider);
        final a = m.attachment!;
        final bytes = await MediaService(client).download(a);
        final file = await PrivateMediaFiles().save(bytes,
          extension: (a['filename'] as String).split('.').last,
          expiresAt: attachmentDeadline(a));
        try {
          if (!mounted) return;
          final upload = await MediaService(
            client,
          ).upload(cid, file, forcedKind: m.kind, preserveBytes: true, displayFilename: a['filename']);
          if (!mounted) return;
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
          bytes.fillRange(0, bytes.length, 0);
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
    if (m.viewOnce) {
      await showModalBottomSheet<void>(
        context: context,
        builder: (c) => SafeArea(
          child: ListTile(
            title: const Text('Delete for me'),
            onTap: () {
              Navigator.pop(c);
              act(context, () => ref.read(messengerProvider).hide(m.id));
            },
          ),
        ),
      );
      return;
    }
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

  Widget bubble(ChatMessage m, {ChatMessage? quoted}) {
    final own = m.senderId == ref.read(messengerProvider).uid;
    final colors = Theme.of(context).colorScheme;
    final style = MessengerStyle.of(context);
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
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
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
              padding: EdgeInsets.all(style.compact ? 9 : 12),
              decoration: BoxDecoration(
                gradient: style.accent != null && own ? LinearGradient(colors: style.accent!.colors.map((color) => Color.alphaBlend(color.withValues(alpha: .18), colors.surface)).toList()) : null,
                border: style.accent != null && own ? Border.all(color: colors.primary, width: 2) : null,
                color: own
                    ? colors.primaryContainer
                    : colors.surfaceContainerHighest,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(style.radius),
                  topRight: Radius.circular(style.radius),
                  bottomLeft: Radius.circular(own ? style.radius : 4),
                  bottomRight: Radius.circular(own ? 4 : style.radius),
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
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            quoted?.senderName ?? 'Reply',
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                          Text(
                            quoted == null
                                ? 'Original message not loaded'
                                : quoted.deleted
                                ? 'Message deleted'
                                : quoted.body.isNotEmpty
                                ? quoted.body
                                : quoted.attachment?['filename'] ?? quoted.kind,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  if (m.deleted)
                    const Text(
                      'Message deleted',
                      style: TextStyle(fontStyle: FontStyle.italic),
                    )
                  else ...[
                    if (['image', 'video'].contains(m.kind) && m.attachment == null && !m.viewOnce)
                      const Text('Media expired')
                    else if (m.viewOnce)
                      ViewOnceTile(message: m)
                    else if (m.attachment != null)
                      AttachmentView(
                        key: ValueKey(m.id),
                        client: ref.read(supabaseProvider),
                        attachment: m.attachment!,
                        kind: m.kind,
                        expiresAt: m.expiresAt,
                      ),
                    if (!m.viewOnce && m.body.isNotEmpty)
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
        if (detailsLoaded && !selfChat) for (final video in [false, true])
          IconButton(
            tooltip: video ? 'Video call' : 'Voice call',
            icon: Icon(video ? Icons.videocam_outlined : Icons.call_outlined),
            onPressed: () => act(context, () async {
              final id = await ref
                  .read(callInitiatorProvider)
                  .start(widget.id, video);
              if (context.mounted) context.push('/call/$id');
            }),
          ),
        PopupMenuButton<String>(
          tooltip: 'Conversation options',
          onSelected: (value) {
            if (value == 'wallpaper') {
              act(context, chooseWallpaper);
            } else {
              context.push('/details/${widget.id}');
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'details', child: Text('Details and members')),
            PopupMenuItem(value: 'wallpaper', child: Text('Chat wallpaper')),
          ],
        ),
      ],
    ),
    body: ChatBackdrop(
      style: wallpaper,
      child: Column(
        children: [
          if (ref.read(messengerProvider).onlineOnly)
            const ListTile(
              dense: true,
              leading: Icon(Icons.lock_outline),
              title: Text('Online-only recovery mode'),
              subtitle: Text('Encrypted drafts stay untouched. Text, photos and videos require server confirmation; other files remain unavailable.'),
            ),
          ExpirationBanner(cid: widget.id, canChange: direct || admin),
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
                scheduleRetention(merged.values.toList());
                final rows =
                    searchResults?.where((m) => !m.expired).toList() ??
                    (merged.values
                        .where(
                          (m) =>
                              !m.expired &&
                              !ref.read(messengerProvider).isHidden(m.id),
                        )
                        .toList()
                      ..sort(ChatMessage.newestFirst));
                if (s.hasError && rows.isEmpty) {
                  return LoadError(
                    retry: () => setState(
                      () => messages = ref
                          .read(messengerProvider)
                          .messages(
                            widget.id,
                            historyIds: () => older.map((m) => m.id),
                          ),
                    ),
                  );
                }
                if (!s.hasData && rows.isEmpty) {
                  return const Center(child: CircularProgressIndicator());
                }
                final incoming = rows
                    .where((m) => m.senderId != ref.read(messengerProvider).uid)
                    .firstOrNull;
                if (incoming != null &&
                    lastAck != incoming.id &&
                    !acknowledging) {
                  acknowledging = true;
                  final client = ref.read(supabaseProvider);
                  unawaited(() async {
                    try {
                      await client.rpc(
                        'ack_messages',
                        params: {'cid': widget.id, 'mark_read': true},
                      );
                      if (mounted) lastAck = incoming.id;
                    } catch (_) {
                      // Leave lastAck unchanged so a reconnect/poll retries it.
                    } finally {
                      acknowledging = false;
                    }
                  }());
                }
                return Column(
                  children: [
                    if (s.hasError)
                      const Text(
                        'Offline · showing previously loaded messages',
                      ),
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
                              keyboardDismissBehavior:
                                  ScrollViewKeyboardDismissBehavior.onDrag,
                              itemCount: rows.length + 1,
                              findChildIndexCallback: (key) {
                                if (key is! ValueKey<String>) return null;
                                final index = rows.indexWhere(
                                  (row) => row.id == key.value,
                                );
                                return index < 0 ? null : index;
                              },
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
                                                            ChatMessage
                                                                .fromJson,
                                                          ),
                                                        );
                                                        hasOlder =
                                                            page.length == 50;
                                                      });
                                                    }
                                                  } finally {
                                                    if (mounted) {
                                                      setState(
                                                        () => loadingOlder =
                                                            false,
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
                                  key: ValueKey(m.id),
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
                                    bubble(
                                      m,
                                      quoted:
                                          merged[m.replyTo]?.expired == false
                                          ? merged[m.replyTo]
                                          : null,
                                    ),
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
                        if (direct && !selfChat) 'image_once': 'View-once photo',
                        if (direct && !selfChat) 'video_once': 'View-once video',
                        'camera': 'Camera',
                        'video': 'Video',
                        'file': 'File or audio',
                        'contact': 'Contact card',
                        'location': 'Current location',
                        if (!selfChat) 'mention': 'Mention member',
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
                    onPressed: sending ? null : () => act(context, send),
                    icon: const Icon(Icons.arrow_upward),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
