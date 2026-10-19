import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';
import '../../core/security/private_media_files.dart';
import '../../core/security/local_retention.dart';
import '../../providers/app_providers.dart';
import 'full_screen_image_viewer.dart';
import 'full_screen_video_viewer.dart';
import 'media_service.dart';

/// Visual attachments never retain a bearer signed URL. Bytes are downloaded
/// under current RLS and destroyed at the original upload deadline or relock.
class ExpiringAttachmentView extends ConsumerStatefulWidget {
  const ExpiringAttachmentView({
    super.key,
    required this.client,
    required this.attachment,
    required this.kind,
    this.loader,
  });

  final SupabaseClient client;
  final Map<String, dynamic> attachment;
  final String kind;

  /// Test seam; production always uses the approved authenticated download.
  final Future<Uint8List> Function()? loader;

  @override
  ConsumerState<ExpiringAttachmentView> createState() =>
      _ExpiringAttachmentViewState();
}

class _ExpiringAttachmentViewState extends ConsumerState<ExpiringAttachmentView>
    with WidgetsBindingObserver {
  Uint8List? bytes;
  File? file;
  VideoPlayerController? player;
  Timer? timer;
  double? downloadProgress;
  bool closed = false, failed = false, loading = false;
  late final lock = ref.read(lockProvider);

  DateTime? get deadline {
    final media = attachmentDeadline(widget.attachment);
    final message = DateTime.tryParse(
      widget.attachment['expires_at']?.toString() ?? '',
    );
    return media == null
        ? null
        : message != null && message.isBefore(media)
        ? message
        : media;
  }

  @override
  void initState() {
    super.initState();
    lock.addListener(locked);
    WidgetsBinding.instance.addObserver(this);
    final expiry = deadline;
    if (expiry == null || !expiry.isAfter(DateTime.now()) || !lock.unlocked) {
      closed = true;
    } else {
      timer = Timer(expiry.difference(DateTime.now()), close);
      if (widget.kind == 'image') unawaited(load());
    }
  }

  void locked() {
    if (!lock.unlocked) close();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) close();
  }

  Future<void> load() async {
    if (loading || closed) return;
    setState(() {
      loading = true;
      failed = false;
      downloadProgress = 0;
    });
    try {
      final data = await (widget.loader?.call() ??
          MediaService(
            widget.client,
            canUseLocalCache: () =>
                mounted &&
                lock.unlocked &&
                ref.read(authServiceProvider)?.signedIn == true &&
                ref.read(authServiceProvider)?.deviceAuthorized == true,
          ).download(
            widget.attachment,
            onProgress: (p) {
              if (mounted) setState(() => downloadProgress = p);
            },
          ));
      if (!mounted || closed) {
        data.fillRange(0, data.length, 0);
        return;
      }
      timer?.cancel();
      final currentDeadline = deadline;
      if (currentDeadline == null || !currentDeadline.isAfter(DateTime.now())) {
        data.fillRange(0, data.length, 0);
        close();
        return;
      }
      timer = Timer(currentDeadline.difference(DateTime.now()), close);
      bytes = data;
      if (widget.kind == 'video') {
        final owned = await PrivateMediaFiles().video(
          data,
          expiresAt: deadline,
        );
        if (!mounted || closed) {
          if (await owned.exists()) await owned.delete();
          return;
        }
        file = owned;
        final controller = VideoPlayerController.file(owned);
        player = controller;
        await controller.initialize();
        if (!mounted || closed) return;
      }
      if (mounted && !closed) setState(() {});
    } catch (_) {
      if (mounted && !closed) setState(() => failed = true);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void forget() {
    final old = bytes;
    bytes = null;
    if (old != null) {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      old.fillRange(0, old.length, 0);
    }
    final video = player;
    player = null;
    final owned = file;
    file = null;
    unawaited(() async {
      await video?.dispose();
      if (owned != null && await owned.exists()) await owned.delete();
    }());
  }

  void close() {
    if (closed) return;
    closed = true;
    forget();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    closed = true;
    timer?.cancel();
    lock.removeListener(locked);
    WidgetsBinding.instance.removeObserver(this);
    forget();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    if (closed) return const Text('Media expired');
    if (failed) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Media unavailable'),
          TextButton.icon(
            onPressed: () {
              setState(() {
                failed = false;
                loading = false;
              });
              load();
            },
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Retry'),
          ),
        ],
      );
    }
    if (!loading && widget.kind == 'video' && bytes == null) {
      return TextButton.icon(
        onPressed: load,
        icon: const Icon(Icons.play_circle),
        label: const Text('Play video'),
      );
    }
    if (bytes == null ||
        (widget.kind == 'video' && player?.value.isInitialized != true)) {
      return SizedBox(
        height: 100,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 120,
                child: LinearProgressIndicator(value: downloadProgress),
              ),
              if (downloadProgress != null && downloadProgress! > 0) ...[
                const SizedBox(height: 6),
                Text(
                  '${(downloadProgress! * 100).toInt()}%',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ],
          ),
        ),
      );
    }
    if (widget.kind == 'image') {
      return GestureDetector(
        onTap: () {
          if (bytes == null) return;
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => FullScreenImageViewer(
                bytes: bytes!,
                expiresAt: deadline,
                filename: widget.attachment['filename'],
                sizeBytes: widget.attachment['size_bytes'],
                attachment: widget.attachment,
                client: widget.client,
              ),
            ),
          );
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Image.memory(
            bytes!,
            width: 240,
            height: 180,
            fit: BoxFit.cover,
            cacheWidth: 720,
            errorBuilder: (_, _, _) => const Text('Media unavailable'),
          ),
        ),
      );
    }
    return playback(player!);
  }

  Widget playback(VideoPlayerController video) => ListenableBuilder(
    listenable: video,
    builder: (context, _) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AspectRatio(
            aspectRatio: video.value.aspectRatio > 0
                ? video.value.aspectRatio
                : 16 / 9,
            child: Stack(
              alignment: Alignment.center,
              children: [
                VideoPlayer(video),
                if (!video.value.isPlaying)
                  Container(
                    decoration: const BoxDecoration(
                      color: Colors.black38,
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      iconSize: 42,
                      icon: const Icon(Icons.play_arrow, color: Colors.white),
                      onPressed: () => video.play(),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        VideoProgressIndicator(video, allowScrubbing: true),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: video.value.isPlaying ? 'Pause video' : 'Play video',
              onPressed: () {
                video.value.isPlaying ? video.pause() : video.play();
              },
              icon: Icon(
                video.value.isPlaying ? Icons.pause : Icons.play_arrow,
              ),
            ),
            Text(
              '${_formatDuration(video.value.position)} / ${_formatDuration(video.value.duration)}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Full screen video',
              icon: const Icon(Icons.fullscreen),
              onPressed: () {
                video.pause();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => FullScreenVideoViewer(
                      file: file!,
                      expiresAt: deadline,
                      filename: widget.attachment['filename'],
                      initialPosition: video.value.position,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ],
    ),
  );
}
