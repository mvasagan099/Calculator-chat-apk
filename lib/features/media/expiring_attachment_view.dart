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
import 'media_service.dart';
import 'private_media_guard.dart';

/// Visual attachments never retain a bearer signed URL. Bytes are downloaded
/// under current RLS and destroyed at the original upload deadline or relock.
class ExpiringAttachmentView extends ConsumerStatefulWidget {
  const ExpiringAttachmentView({super.key, required this.client, required this.attachment, required this.kind, this.loader});
  final SupabaseClient client;
  final Map<String, dynamic> attachment;
  final String kind;
  /// Test seam; production always uses the approved authenticated download.
  final Future<Uint8List> Function()? loader;
  @override
  ConsumerState<ExpiringAttachmentView> createState() => _ExpiringAttachmentViewState();
}

class _ExpiringAttachmentViewState extends ConsumerState<ExpiringAttachmentView> with WidgetsBindingObserver {
  Uint8List? bytes;
  File? file;
  VideoPlayerController? player;
  Timer? timer;
  bool closed = false, failed = false, loading = false;
  late final lock = ref.read(lockProvider);
  DateTime? get deadline {
    final media = attachmentDeadline(widget.attachment);
    final message = DateTime.tryParse(widget.attachment['expires_at']?.toString() ?? '');
    return media == null ? null : message != null && message.isBefore(media) ? message : media;
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
  void locked() { if (!lock.unlocked) close(); }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) close();
  }
  Future<void> load() async {
    if (loading || closed) return;
    setState(() => loading = true);
    try {
      final data = await (widget.loader?.call() ?? MediaService(widget.client).download(widget.attachment));
      if (!mounted || closed) { data.fillRange(0, data.length, 0); return; }
      timer?.cancel();
      final currentDeadline = deadline;
      if (currentDeadline == null || !currentDeadline.isAfter(DateTime.now())) {
        data.fillRange(0, data.length, 0); close(); return;
      }
      timer = Timer(currentDeadline.difference(DateTime.now()), close);
      bytes = data;
      if (widget.kind == 'video') {
        final owned = await PrivateMediaFiles().video(data, expiresAt: deadline);
        if (!mounted || closed) { if (await owned.exists()) await owned.delete(); return; }
        file = owned;
        final controller = VideoPlayerController.file(owned);
        player = controller;
        await controller.initialize();
        if (!mounted || closed) return;
      }
      if (mounted && !closed) setState(() {});
    } catch (_) { if (mounted && !closed) setState(() => failed = true); }
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
  @override
  Widget build(BuildContext context) {
    if (closed) return const Text('Media expired');
    if (failed) return const Text('Media unavailable');
    if (!loading && widget.kind == 'video') return TextButton.icon(onPressed: load, icon: const Icon(Icons.play_circle), label: const Text('Play video'));
    if (bytes == null || (widget.kind == 'video' && player?.value.isInitialized != true)) {
      return const SizedBox(height: 100, child: Center(child: CircularProgressIndicator()));
    }
    if (widget.kind == 'image') {
      return GestureDetector(
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PrivateMediaGuard(
          expiresAt: deadline,
          builder: (_) => Scaffold(appBar: AppBar(), body: Center(child: InteractiveViewer(
            child: Image.memory(bytes!, cacheWidth: 2160, errorBuilder: (_, _, _) => const Text('Media expired'))))),
        ))),
        child: ClipRRect(borderRadius: BorderRadius.circular(14), child: Image.memory(bytes!,
          width: 240, height: 180, fit: BoxFit.cover, cacheWidth: 720,
          errorBuilder: (_, _, _) => const Text('Media unavailable'))),
      );
    }
    return playback(player!);
  }
  Widget playback(VideoPlayerController video, {bool fullscreen = false}) => ListenableBuilder(
    listenable: video,
    builder: (context, _) => Column(mainAxisSize: MainAxisSize.min, children: [
      AspectRatio(aspectRatio: video.value.aspectRatio, child: VideoPlayer(video)),
      VideoProgressIndicator(video, allowScrubbing: true),
      Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(tooltip: video.value.isPlaying ? 'Pause video' : 'Play video',
          onPressed: () { video.value.isPlaying ? video.pause() : video.play(); },
          icon: Icon(video.value.isPlaying ? Icons.pause : Icons.play_arrow)),
        if (!fullscreen) IconButton(tooltip: 'Full screen video', icon: const Icon(Icons.fullscreen),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PrivateMediaGuard(
            expiresAt: deadline,
            builder: (_) => Scaffold(appBar: AppBar(title: const Text('Video')), body: Center(child: playback(video, fullscreen: true))),
          )))),
      ]),
    ]),
  );
}
