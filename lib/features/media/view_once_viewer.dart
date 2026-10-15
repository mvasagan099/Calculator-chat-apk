import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import '../../core/security/private_media_files.dart';
import '../../providers/app_providers.dart';
import '../../models/message.dart';

class ViewOnceTile extends ConsumerWidget {
  const ViewOnceTile({super.key, required this.message});
  final ChatMessage message;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final own =
        message.senderId == ref.read(supabaseProvider).auth.currentUser?.id;
    final opened = message.viewOnceOpenedAt != null;
    return TextButton.icon(
      icon: Icon(
        opened ? Icons.check_circle_outline : Icons.looks_one_outlined,
      ),
      label: Text(
        opened
            ? 'Opened'
            : own
            ? 'View-once ${message.kind} sent'
            : 'Open ${message.kind} once',
      ),
      onPressed: own || opened || message.expired
          ? null
          : () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ViewOnceViewer(message: message),
              ),
            ),
    );
  }
}

class ViewOnceViewer extends ConsumerStatefulWidget {
  const ViewOnceViewer({super.key, required this.message, this.loader});
  final ChatMessage message;

  /// Transport seam for renderer lifecycle tests. Production uses the real
  /// authenticated Edge Function, which claims access before returning bytes.
  final Future<Uint8List> Function(String messageId, Future<void> abort)?
  loader;
  @override
  ConsumerState<ViewOnceViewer> createState() => _ViewOnceViewerState();
}

class _ViewOnceViewerState extends ConsumerState<ViewOnceViewer>
    with WidgetsBindingObserver {
  final abort = Completer<void>();
  Timer? expiration;
  VideoPlayerController? player;
  File? file;
  Uint8List? bytes;
  bool closed = false, failed = false;
  late final lock = ref.read(lockProvider);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    lock.addListener(_locked);
    final deadline = widget.message.expiresAt;
    if (deadline != null) {
      final remaining = deadline.difference(DateTime.now());
      expiration = Timer(
        remaining.isNegative ? Duration.zero : remaining,
        _close,
      );
    }
    unawaited(_load());
  }

  void _locked() {
    if (!lock.unlocked) _close();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _close();
  }

  Future<void> _load() async {
    try {
      if (!lock.unlocked || widget.message.expired) {
        _close();
        return;
      }
      final Uint8List data;
      if (widget.loader != null) {
        data = await widget.loader!(widget.message.id, abort.future);
      } else {
        final response = await ref
            .read(supabaseProvider)
            .functions
            .invoke(
              'view-once',
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'message_id': widget.message.id}),
              abortSignal: abort.future,
            );
        if (response.status != 200 || response.data is! Uint8List) {
          throw StateError('Media unavailable');
        }
        data = response.data as Uint8List;
      }
      if (closed || !mounted) {
        data.fillRange(0, data.length, 0);
        return;
      }
      if (data.isEmpty || data.length > 25 * 1024 * 1024) {
        throw StateError('Media unavailable');
      }
      bytes = data;
      if (widget.message.kind == 'video') {
        final created = await PrivateMediaFiles().video(data);
        if (closed || !mounted) {
          await created.delete();
          return;
        }
        file = created;
        final video = VideoPlayerController.file(created);
        player = video;
        await video.initialize();
        if (closed || !mounted) {
          await video.dispose();
          return;
        }
        await video.play();
      }
      if (mounted && !closed) setState(() {});
    } catch (_) {
      if (mounted && !closed) setState(() => failed = true);
    }
  }

  void _forgetImage() {
    final previous = bytes;
    bytes = null;
    if (previous != null) {
      unawaited(
        ResizeImage.resizeIfNeeded(2160, null, MemoryImage(previous))
            .evict()
            .then((_) {
              previous.fillRange(0, previous.length, 0);
            })
            .catchError((Object _) {}),
      );
    }
  }

  void _close() {
    if (closed) return;
    closed = true;
    expiration?.cancel();
    if (!abort.isCompleted) abort.complete();
    unawaited(player?.dispose().catchError((Object _) {}) ?? Future.value());
    player = null;
    final previous = file;
    file = null;
    if (previous != null) {
      unawaited(previous.delete().then((_) {}).catchError((Object _) {}));
    }
    _forgetImage();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    lock.removeListener(_locked);
    expiration?.cancel();
    // No setState is allowed while unmounting.
    if (!closed) {
      closed = true;
      if (!abort.isCompleted) abort.complete();
      unawaited(player?.dispose().catchError((Object _) {}) ?? Future.value());
      final previous = file;
      if (previous != null) {
        unawaited(previous.delete().then((_) {}).catchError((Object _) {}));
      }
      _forgetImage();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('View once')),
    body: Center(
      child: closed
          ? const Text('Closed. This media cannot be reopened here.')
          : failed
          ? const Text('Opening failed. It may already have been consumed.')
          : player != null && player!.value.isInitialized
          ? AspectRatio(
              aspectRatio: player!.value.aspectRatio,
              child: VideoPlayer(player!),
            )
          : widget.message.kind == 'image' && bytes != null
          ? InteractiveViewer(
              child: Image.memory(
                bytes!,
                cacheWidth: 2160,
                errorBuilder: (_, _, _) => const Text('Media unavailable'),
              ),
            )
          : const CircularProgressIndicator(),
    ),
  );
}
