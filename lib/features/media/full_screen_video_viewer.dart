import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';
import '../../core/widgets/actions.dart';
import '../vault/save_to_vault_action.dart';
import 'private_media_guard.dart';

class FullScreenVideoViewer extends ConsumerStatefulWidget {
  const FullScreenVideoViewer({
    super.key,
    required this.file,
    this.expiresAt,
    this.filename,
    this.initialPosition,
    this.attachment,
    this.client,
  });

  final File file;
  final DateTime? expiresAt;
  final String? filename;
  final Duration? initialPosition;
  final Map<String, dynamic>? attachment;
  final SupabaseClient? client;

  @override
  ConsumerState<FullScreenVideoViewer> createState() =>
      _FullScreenVideoViewerState();
}

class _FullScreenVideoViewerState extends ConsumerState<FullScreenVideoViewer> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _showControls = true;
  Timer? _hideControlsTimer;
  double _speed = 1.0;
  bool _muted = false;
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    final controller = VideoPlayerController.file(widget.file);
    _controller = controller;
    await controller.initialize();
    if (widget.initialPosition != null &&
        widget.initialPosition! > Duration.zero) {
      await controller.seekTo(widget.initialPosition!);
    }
    await controller.play();
    if (mounted) {
      setState(() => _initialized = true);
      _resetHideTimer();
    }
  }

  void _resetHideTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && (_controller?.value.isPlaying ?? false)) {
        setState(() => _showControls = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _resetHideTimer();
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      return '${d.inHours}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(widget.file.path)]),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final video = _controller;
    return PrivateMediaGuard(
      expiresAt: widget.expiresAt,
      builder: (context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: _showControls
            ? AppBar(
                backgroundColor: Colors.black.withValues(alpha: 0.7),
                iconTheme: const IconThemeData(color: Colors.white),
                title: Text(
                  widget.filename ?? 'Video',
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                actions: [
                  IconButton(
                    tooltip: 'Save to Vault',
                    icon: const Icon(Icons.lock_outline, color: Colors.white),
                    onPressed: () => act(context, () async {
                      final client = widget.client ?? Supabase.instance.client;
                      final bytes = await widget.file.readAsBytes();
                      if (!context.mounted) return;
                      await saveChatAttachmentToVault(
                        context: context,
                        ref: ref,
                        client: client,
                        attachment: widget.attachment ?? {
                          'filename': widget.filename ?? 'video.mp4',
                          'mime_type': 'video/mp4',
                          'size_bytes': bytes.length,
                        },
                        preloadedBytes: bytes,
                      );
                    }),
                  ),
                  IconButton(
                    tooltip: 'Share',
                    icon: _sharing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.ios_share, color: Colors.white),
                    onPressed: _sharing ? null : () => act(context, _share),
                  ),
                ],
              )
            : null,
        body: Center(
          child: !_initialized || video == null
              ? const CircularProgressIndicator(color: Colors.white)
              : GestureDetector(
                  onTap: _toggleControls,
                  behavior: HitTestBehavior.opaque,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      AspectRatio(
                        aspectRatio: video.value.aspectRatio > 0
                            ? video.value.aspectRatio
                            : 16 / 9,
                        child: VideoPlayer(video),
                      ),
                      if (_showControls) ...[
                        // Big Play / Pause / Replay in center
                        ListenableBuilder(
                          listenable: video,
                          builder: (context, _) {
                            final isEnded = video.value.position >=
                                video.value.duration;
                            return Container(
                              decoration: const BoxDecoration(
                                color: Colors.black45,
                                shape: BoxShape.circle,
                              ),
                              child: IconButton(
                                iconSize: 56,
                                icon: Icon(
                                  isEnded
                                      ? Icons.replay
                                      : video.value.isPlaying
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                  color: Colors.white,
                                ),
                                onPressed: () {
                                  if (isEnded) {
                                    video.seekTo(Duration.zero);
                                    video.play();
                                  } else if (video.value.isPlaying) {
                                    video.pause();
                                  } else {
                                    video.play();
                                  }
                                  _resetHideTimer();
                                },
                              ),
                            );
                          },
                        ),
                        // Bottom control bar
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Container(
                            color: Colors.black.withValues(alpha: 0.7),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            child: ListenableBuilder(
                              listenable: video,
                              builder: (context, _) => Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        _formatDuration(video.value.position),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                        ),
                                      ),
                                      Expanded(
                                        child: Slider(
                                          value: video.value.position.inMilliseconds
                                              .clamp(
                                                0,
                                                video.value.duration.inMilliseconds,
                                              )
                                              .toDouble(),
                                          max: (video.value.duration.inMilliseconds > 0
                                                  ? video.value.duration.inMilliseconds
                                                  : 1)
                                              .toDouble(),
                                          activeColor: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                          inactiveColor: Colors.white24,
                                          onChanged: (val) {
                                            video.seekTo(
                                              Duration(
                                                milliseconds: val.round(),
                                              ),
                                            );
                                            _resetHideTimer();
                                          },
                                        ),
                                      ),
                                      Text(
                                        _formatDuration(video.value.duration),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            tooltip: _muted
                                                ? 'Unmute'
                                                : 'Mute',
                                            icon: Icon(
                                              _muted
                                                  ? Icons.volume_off
                                                  : Icons.volume_up,
                                              color: Colors.white,
                                              size: 20,
                                            ),
                                            onPressed: () {
                                              setState(() {
                                                _muted = !_muted;
                                                video.setVolume(
                                                  _muted ? 0.0 : 1.0,
                                                );
                                              });
                                              _resetHideTimer();
                                            },
                                          ),
                                          TextButton(
                                            onPressed: () {
                                              setState(() {
                                                _speed = _speed == 1.0
                                                    ? 1.5
                                                    : _speed == 1.5
                                                    ? 2.0
                                                    : 1.0;
                                                video.setPlaybackSpeed(_speed);
                                              });
                                              _resetHideTimer();
                                            },
                                            child: Text(
                                              '$_speed×',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}
