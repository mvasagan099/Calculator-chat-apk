import '../../core/security/local_retention.dart';
import 'expiring_attachment_view.dart';
import 'dart:typed_data';
import '../../core/security/private_media_files.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
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
    this.expiresAt,
  });
  final SupabaseClient client;
  final Map<String, dynamic> attachment;
  final String kind;
  final DateTime? expiresAt;
  @override
  State<AttachmentView> createState() => _AttachmentViewState();
}

class _AttachmentViewState extends State<AttachmentView> {
  Map<String, dynamic> get attachment => {
    ...widget.attachment,
    if (widget.expiresAt != null)
      'expires_at': widget.expiresAt!.toUtc().toIso8601String(),
  };
  AudioPlayer? player;
  bool playing = false, preparingAudio = false;
  StreamSubscription<PlayerState>? _playerState;
  double speed = 1;
  double? downloadProgress;
  bool downloading = false;
  @override
  void dispose() {
    _playerState?.cancel();
    player?.dispose();
    super.dispose();
  }

  Future<void> play() async {
    if (preparingAudio) return;
    AudioPlayer? current = player;
    if (current == null) {
      setState(() => preparingAudio = true);
      current = AudioPlayer();
      player = current;
      _playerState = current.playerStateStream.listen((s) {
        if (mounted) {
          setState(
            () => playing =
                s.playing && s.processingState != ProcessingState.completed,
          );
        }
      });
      try {
        // A URL created when the bubble mounted may already have expired.
        final source = await MediaService(widget.client).signedUrl(attachment);
        if (!mounted) return;
        await current.setUrl(source);
        if (!mounted) return;
        await current.setSpeed(speed);
      } catch (_) {
        if (mounted) {
          await _playerState?.cancel();
          player = null;
          await current.dispose();
        }
        rethrow;
      } finally {
        if (mounted) setState(() => preparingAudio = false);
      }
    }
    if (!mounted) return;
    if (playing) {
      await current.pause();
    } else {
      if (current.processingState == ProcessingState.completed) {
        await current.seek(Duration.zero);
      }
      if (mounted) await current.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = attachment;
    if (visualAttachmentExpired(a, DateTime.now())) return const Text('Media expired');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (downloading) LinearProgressIndicator(value: downloadProgress),
        if (widget.kind == 'image' || widget.kind == 'video')
          ExpiringAttachmentView(key: ValueKey(a['media_expires_at']), client: widget.client, attachment: a, kind: widget.kind),
        if (widget.kind == 'audio' || widget.kind == 'voice')
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: playing ? 'Pause' : 'Play',
                onPressed: preparingAudio ? null : () => act(context, play),
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
                late final Uint8List bytes;
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
                if (!mounted || visualAttachmentExpired(a, DateTime.now())) {
                  bytes.fillRange(0, bytes.length, 0);
                  return;
                }
                final file = await PrivateMediaFiles().save(bytes,
                  extension: (a['filename'] as String).split('.').last,
                  expiresAt: attachmentDeadline(a));
                try {
                  await SharePlus.instance.share(
                    ShareParams(files: [XFile(file.path)]),
                  );
                } finally {
                  bytes.fillRange(0, bytes.length, 0);
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
