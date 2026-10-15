import 'dart:io';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/widgets/actions.dart';
import 'media_service.dart';

class AttachmentView extends StatefulWidget {
  const AttachmentView({
    super.key,
    required this.client,
    required this.attachment,
    required this.kind,
  });
  final SupabaseClient client;
  final Map<String, dynamic> attachment;
  final String kind;
  @override
  State<AttachmentView> createState() => _AttachmentViewState();
}

class _AttachmentViewState extends State<AttachmentView> {
  late final Future<String> url = MediaService(
    widget.client,
  ).signedUrl(widget.attachment);
  AudioPlayer? player;
  bool playing = false;
  double speed = 1;
  double? downloadProgress;
  bool downloading = false;
  @override
  void dispose() {
    player?.dispose();
    super.dispose();
  }

  Future<void> play() async {
    if (player == null) {
      player = AudioPlayer();
      await player!.setUrl(await url);
      player!.playerStateStream.listen((s) {
        if (mounted) {
          setState(
            () => playing =
                s.playing && s.processingState != ProcessingState.completed,
          );
        }
      });
    }
    if (playing) {
      await player!.pause();
    } else {
      if (player!.processingState == ProcessingState.completed) {
        await player!.seek(Duration.zero);
      }
      await player!.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.attachment;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (downloading) LinearProgressIndicator(value: downloadProgress),
        if (widget.kind == 'image')
          FutureBuilder<String>(
            future: url,
            builder: (context, s) => s.hasData
                ? GestureDetector(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => Scaffold(
                          appBar: AppBar(),
                          body: Center(
                            child: InteractiveViewer(
                              child: Image.network(
                                s.data!,
                                errorBuilder: (_, _, _) =>
                                    const Icon(Icons.broken_image),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Image.network(
                        s.data!,
                        width: 240,
                        height: 180,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) =>
                            const Icon(Icons.broken_image),
                      ),
                    ),
                  )
                : const SizedBox(
                    height: 100,
                    child: Center(child: CircularProgressIndicator()),
                  ),
          ),
        if (widget.kind == 'audio' || widget.kind == 'voice')
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: playing ? 'Pause' : 'Play',
                onPressed: () => act(context, play),
                icon: Icon(playing ? Icons.pause_circle : Icons.play_circle),
              ),
              StreamBuilder<Duration>(
                stream: player?.positionStream,
                builder: (context, s) =>
                    Text('${(s.data ?? Duration.zero).inSeconds}s'),
              ),
              TextButton(
                onPressed: () {
                  setState(
                    () => speed = speed == 1
                        ? 1.5
                        : speed == 1.5
                        ? 2
                        : 1,
                  );
                  player?.setSpeed(speed);
                },
                child: Text('$speed×'),
              ),
            ],
          ),
        if (widget.kind == 'video')
          TextButton.icon(
            onPressed: () => act(context, () async {
              final source = await url;
              if (context.mounted) {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => VideoViewer(url: source)),
                );
              }
            }),
            icon: const Icon(Icons.play_circle),
            label: const Text('Play video'),
          ),
        Text(a['filename'], maxLines: 1, overflow: TextOverflow.ellipsis),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${((a['size_bytes'] as num) / 1024).ceil()} KB',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            IconButton(
              tooltip: 'Download and share',
              icon: const Icon(Icons.ios_share, size: 18),
              onPressed: () => act(context, () async {
                if (downloading) return;
                setState(() {
                  downloading = true;
                  downloadProgress = 0;
                });
                late final List<int> bytes;
                try {
                  bytes = await MediaService(widget.client).download(
                    a,
                    onProgress: (value) {
                      if (mounted) setState(() => downloadProgress = value);
                    },
                  );
                } finally {
                  if (mounted) setState(() => downloading = false);
                }
                if (!mounted) return;
                final directory = await getTemporaryDirectory();
                final basename = (a['filename'] as String).replaceAll(
                  RegExp(r'[^a-zA-Z0-9._-]'),
                  '_',
                );
                final file = File(
                  '${directory.path}/${a['id'] ?? 'export'}-$basename',
                );
                await file.writeAsBytes(bytes);
                try {
                  await SharePlus.instance.share(
                    ShareParams(files: [XFile(file.path)]),
                  );
                } finally {
                  if (await file.exists()) await file.delete();
                }
              }),
            ),
          ],
        ),
      ],
    );
  }
}

class VideoViewer extends StatefulWidget {
  const VideoViewer({super.key, required this.url});
  final String url;
  @override
  State<VideoViewer> createState() => _VideoViewerState();
}

class _VideoViewerState extends State<VideoViewer> {
  late final VideoPlayerController controller =
      VideoPlayerController.networkUrl(Uri.parse(widget.url));
  late final Future<void> ready = controller.initialize();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Video')),
    body: FutureBuilder<void>(
      future: ready,
      builder: (context, s) {
        if (s.hasError) return const Center(child: Text('Video unavailable'));
        if (s.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AspectRatio(
                aspectRatio: controller.value.aspectRatio,
                child: VideoPlayer(controller),
              ),
              VideoProgressIndicator(controller, allowScrubbing: true),
              IconButton(
                onPressed: () {
                  setState(() {
                    controller.value.isPlaying
                        ? controller.pause()
                        : controller.play();
                  });
                },
                icon: Icon(
                  controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}
