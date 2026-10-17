import 'dart:async';
import 'package:video_player/video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../core/widgets/actions.dart';
import '../../core/widgets/private_scaffold.dart';
import '../../providers/app_providers.dart';
import '../../core/services/private_media_access.dart';

class StatusScreen extends ConsumerStatefulWidget {
  const StatusScreen({super.key, this.mediaPicker});
  final Future<XFile?> Function(String kind)? mediaPicker;
  @override
  ConsumerState<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends ConsumerState<StatusScreen> {
  bool posting = false;
  late final stream = ref.read(messengerProvider).watch(
    ['status_updates'],
    () async {
      final client = ref.read(supabaseProvider);
      final muted = await client.from('status_mutes').select('user_id');
      final ids = muted.map((e) => e['user_id']).toSet();
      final rows = await client
          .from('status_updates')
          .select('*,profiles(display_name,avatar_path)')
          .gt('expires_at', DateTime.now().toUtc().toIso8601String())
          .order('created_at', ascending: false)
          .limit(100);
      return rows.where((s) => !ids.contains(s['user_id'])).toList();
    },
  );
  Future<void> create(String kind) async {
    if (posting) return;
    final client = ref.read(supabaseProvider);
    final access = PrivateMediaAccess(ref.read(lockProvider), ref.read(authServiceProvider), client,
        isCurrent: () => mounted);
    access.check();
    setState(() => posting = true);
    try {
      String? path;
      String body = '';
      if (kind == 'text') {
        body =
            await askText(context, 'Your update (up to 1000 characters)') ?? '';
        if (body.isEmpty) return;
      } else {
        final picker = ImagePicker();
        final file = await access.pick<XFile>(kind, () => widget.mediaPicker != null
            ? widget.mediaPicker!(kind)
            : kind == 'image'
            ? picker.pickImage(
                source: ImageSource.gallery,
                imageQuality: 85,
                maxWidth: 1920,
              )
            : picker.pickVideo(
                source: ImageSource.gallery,
                maxDuration: const Duration(seconds: 30),
              ));
        if (file == null) return;
        if (!mounted) return;
        access.check();
        final size = await file.length();
        if (!mounted) return;
        access.check();
        if (size < 1 || size > 25 * 1024 * 1024) {
          throw const FormatException('Files must be between 1 byte and 25 MB');
        }
        final bytes = await file.readAsBytes();
        if (!mounted) return;
        access.check();
        if (bytes.isEmpty || bytes.length > 25 * 1024 * 1024) {
          throw const FormatException('Maximum 25 MB');
        }
        final ext = file.path.split('.').last.toLowerCase();
        final mime = kind == 'video'
            ? 'video/mp4'
            : ext == 'png'
            ? 'image/png'
            : ext == 'webp'
            ? 'image/webp'
            : 'image/jpeg';
        path = '${client.auth.currentUser!.id}/${const Uuid().v4()}.$ext';
        await client.storage
            .from('status-media')
            .uploadBinary(
              path,
              bytes,
              fileOptions: FileOptions(contentType: mime),
            );
        if (!mounted) return;
        access.check();
        final check = await client.functions.invoke(
          'validate-media',
          body: {'bucket': 'status-media', 'path': path},
        );
        if (check.status != 200) throw StateError('Media rejected');
      }
      if (!mounted) return;
      access.check();
      await client.rpc(
        'create_status',
        params: {'content': body, 'media_path': path, 'media_kind': kind},
      );
    } finally {
      if (mounted) setState(() => posting = false);
    }
  }

  @override
  Widget build(BuildContext context) => PrivateScaffold(
    title: 'Updates',
    index: 1,
    actions: [
      PopupMenuButton<String>(
        enabled: !posting,
        icon: const Icon(Icons.add_circle_outline),
        onSelected: (kind) => act(context, () => create(kind)),
        itemBuilder: (_) => [
          for (final kind in ['text', 'image', 'video'])
            PopupMenuItem(value: kind, child: Text('New $kind update')),
        ],
      ),
    ],
    body: Column(
      children: [
        if (posting) const LinearProgressIndicator(),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Updates disappear after 24 hours. Shared with people in your contacts when your status privacy allows it.',
          ),
        ),
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: stream,
            builder: (context, s) {
              if (s.hasError) return LoadError(retry: () => setState(() {}));
              if (!s.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              if (s.data!.isEmpty) {
                return const Center(
                  child: Text('No updates right now. Share a moment.'),
                );
              }
              return ListView(
                children: [
                  for (final status in s.data!)
                    ListTile(
                      leading: PersonAvatar(
                        name: status['profiles']['display_name'],
                        path: status['profiles']['avatar_path'],
                      ),
                      title: Text(status['profiles']['display_name']),
                      subtitle: Text(
                        status['kind'] == 'text'
                            ? status['body']
                            : '${status['kind']} update',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => StatusViewer(status: status),
                        ),
                      ),
                      onLongPress: () => act(context, () async {
                        if (status['user_id'] ==
                            ref.read(messengerProvider).uid) {
                          final action = await showModalBottomSheet<String>(
                            context: context,
                            builder: (c) => SafeArea(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ListTile(
                                    title: const Text('View count'),
                                    onTap: () => Navigator.pop(c, 'views'),
                                  ),
                                  ListTile(
                                    title: const Text('Delete update'),
                                    onTap: () => Navigator.pop(c, 'delete'),
                                  ),
                                ],
                              ),
                            ),
                          );
                          if (action == 'delete') {
                            await ref
                                .read(supabaseProvider)
                                .rpc(
                                  'delete_status',
                                  params: {'sid': status['id']},
                                );
                          }
                          if (action == 'views') {
                            final rows = await ref
                                .read(supabaseProvider)
                                .from('status_views')
                                .select('user_id')
                                .eq('status_id', status['id']);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('${rows.length} views')),
                              );
                            }
                          }
                        } else {
                          await ref
                              .read(supabaseProvider)
                              .from('status_mutes')
                              .upsert({
                                'owner_id': ref.read(messengerProvider).uid,
                                'user_id': status['user_id'],
                              }, ignoreDuplicates: true);
                        }
                      }),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    ),
  );
}

class StatusViewer extends ConsumerStatefulWidget {
  const StatusViewer({super.key, required this.status});
  final Map<String, dynamic> status;
  @override
  ConsumerState<StatusViewer> createState() => _StatusViewerState();
}

class _StatusViewerState extends ConsumerState<StatusViewer> {
  Timer? timer;
  double progress = 0;
  String? url;
  VideoPlayerController? video;
  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      if (!mounted) return;
      await act(context, () async {
        await ref
            .read(supabaseProvider)
            .rpc('view_status', params: {'sid': widget.status['id']});
        if (widget.status['object_path'] != null) {
          final signed = await ref
              .read(supabaseProvider)
              .storage
              .from('status-media')
              .createSignedUrl(widget.status['object_path'], 120);
          if (mounted) setState(() => url = signed);
        }
      });
      if (!mounted) return;
      if (widget.status['kind'] == 'video' && url != null) {
        final controller = VideoPlayerController.networkUrl(Uri.parse(url!));
        video = controller;
        await controller.initialize();
        if (!mounted) {
          await controller.dispose();
          return;
        }
        controller.addListener(() {
          if (!mounted) return;
          final value = controller.value;
          if (value.duration.inMilliseconds > 0) {
            setState(
              () => progress =
                  (value.position.inMilliseconds /
                          value.duration.inMilliseconds)
                      .clamp(0, 1),
            );
            if (progress >= 1) Navigator.pop(context);
          }
        });
        setState(() {});
        unawaited(controller.play());
        return;
      }
      timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (!mounted) return;
        setState(() => progress = (progress + 0.01).clamp(0, 1));
        if (progress >= 1) {
          timer?.cancel();
          Navigator.pop(context);
        }
      });
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.status['profiles']['display_name'])),
    body: Column(
      children: [
        LinearProgressIndicator(value: progress),
        Expanded(
          child: Center(
            child: widget.status['kind'] == 'text'
                ? Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      widget.status['body'],
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                  )
                : url == null
                ? const CircularProgressIndicator()
                : widget.status['kind'] == 'image'
                ? InteractiveViewer(child: Image.network(url!))
                : video?.value.isInitialized == true
                ? AspectRatio(
                    aspectRatio: video!.value.aspectRatio,
                    child: VideoPlayer(video!),
                  )
                : const CircularProgressIndicator(),
          ),
        ),
      ],
    ),
  );
}
