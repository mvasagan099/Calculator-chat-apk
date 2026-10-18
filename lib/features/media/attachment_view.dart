import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/security/local_retention.dart';
import '../../core/security/private_media_files.dart';
import '../../core/widgets/actions.dart';
import '../../providers/app_providers.dart';
import 'document_viewer.dart';
import 'expiring_attachment_view.dart';
import 'media_service.dart';

class AttachmentView extends ConsumerStatefulWidget {
  const AttachmentView({
    super.key,
    required this.client,
    required this.attachment,
    required this.kind,
    this.expiresAt,
    this.preferredSpeed,
  });

  final SupabaseClient client;
  final Map<String, dynamic> attachment;
  final String kind;
  final DateTime? expiresAt;
  final double? preferredSpeed;

  @override
  ConsumerState<AttachmentView> createState() => _AttachmentViewState();
}

class _AttachmentViewState extends ConsumerState<AttachmentView> {
  Map<String, dynamic> get attachment => {
    ...widget.attachment,
    if (widget.expiresAt != null)
      'expires_at': widget.expiresAt!.toUtc().toIso8601String(),
  };

  AudioPlayer? player;
  bool playing = false, preparingAudio = false, audioFailed = false;
  Duration audioPosition = Duration.zero;
  Duration audioDuration = Duration.zero;
  StreamSubscription<PlayerState>? _playerState;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;
  double speed = 1.0;

  double? downloadProgress;
  bool downloading = false;
  bool downloadFailed = false;

  @override
  void initState() {
    super.initState();
    speed = widget.preferredSpeed ?? 1.0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        final settings = ref.read(deviceSettingsProvider);
        if (settings != null && widget.preferredSpeed == null) {
          setState(() => speed = settings.voicePlaybackSpeed);
        }
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _playerState?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    try {
      player?.stop();
    } catch (_) {}
    player?.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> play() async {
    if (preparingAudio) return;
    AudioPlayer? current = player;
    if (current == null) {
      setState(() {
        preparingAudio = true;
        audioFailed = false;
      });
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
      _positionSub = current.positionStream.listen((pos) {
        if (mounted) setState(() => audioPosition = pos);
      });
      _durationSub = current.durationStream.listen((dur) {
        if (mounted && dur != null) setState(() => audioDuration = dur);
      });
      try {
        final source = await MediaService(widget.client).signedUrl(attachment);
        if (!mounted) return;
        await current.setUrl(source);
        if (!mounted) return;
        await current.setSpeed(speed);
      } catch (_) {
        if (mounted) {
          await _playerState?.cancel();
          await _positionSub?.cancel();
          await _durationSub?.cancel();
          player = null;
          await current.dispose();
          setState(() => audioFailed = true);
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

  IconData _fileIcon(String? filename) {
    final ext = filename?.split('.').last.toLowerCase();
    return switch (ext) {
      'pdf' => Icons.picture_as_pdf,
      'txt' => Icons.description,
      'zip' => Icons.folder_zip,
      'vcf' => Icons.contact_page,
      _ => Icons.insert_drive_file,
    };
  }

  Future<void> openDocument() async {
    final a = attachment;
    if (visualAttachmentExpired(a, DateTime.now())) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Document expired')));
      return;
    }

    final filename = a['filename'] as String? ?? 'document';
    final ext = filename.split('.').last.toLowerCase();

    // If it's a plain text file, download and render in our clean in-app reader.
    if (ext == 'txt') {
      setState(() {
        downloading = true;
        downloadFailed = false;
        downloadProgress = 0;
      });
      Uint8List bytes;
      try {
        bytes = await MediaService(widget.client).download(
          a,
          onProgress: (p) {
            if (mounted) setState(() => downloadProgress = p);
          },
        );
      } catch (_) {
        if (mounted) setState(() => downloadFailed = true);
        rethrow;
      } finally {
        if (mounted) setState(() => downloading = false);
      }
      if (!mounted) return;
      final text = utf8.decode(bytes, allowMalformed: true);
      bytes.fillRange(0, bytes.length, 0);
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TextDocumentViewer(
            filename: filename,
            content: text,
            expiresAt: attachmentDeadline(a),
          ),
        ),
      );
      return;
    }

    // For other documents (PDF, ZIP, VCF, etc.): try launching signed URL directly.
    try {
      final url = await MediaService(widget.client).signedUrl(a);
      final uri = Uri.parse(url);
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (launched) return;
    } catch (_) {
      // Fall through to downloading and sharing/opening.
    }

    // If external URL launch is not supported or fails, download and share.
    setState(() {
      downloading = true;
      downloadFailed = false;
      downloadProgress = 0;
    });
    Uint8List bytes;
    try {
      bytes = await MediaService(widget.client).download(
        a,
        onProgress: (p) {
          if (mounted) setState(() => downloadProgress = p);
        },
      );
    } catch (_) {
      if (mounted) setState(() => downloadFailed = true);
      rethrow;
    } finally {
      if (mounted) setState(() => downloading = false);
    }
    if (!mounted || visualAttachmentExpired(a, DateTime.now())) {
      bytes.fillRange(0, bytes.length, 0);
      return;
    }
    final file = await PrivateMediaFiles().save(
      bytes,
      extension: ext,
      expiresAt: attachmentDeadline(a),
    );
    try {
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
    } finally {
      bytes.fillRange(0, bytes.length, 0);
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> downloadAndShare() async {
    if (downloading) return;
    setState(() {
      downloading = true;
      downloadFailed = false;
      downloadProgress = 0;
    });
    final a = attachment;
    late final Uint8List bytes;
    try {
      bytes = await MediaService(widget.client).download(
        a,
        onProgress: (value) {
          if (mounted) setState(() => downloadProgress = value);
        },
      );
    } catch (_) {
      if (mounted) setState(() => downloadFailed = true);
      rethrow;
    } finally {
      if (mounted) setState(() => downloading = false);
    }
    if (!mounted || visualAttachmentExpired(a, DateTime.now())) {
      bytes.fillRange(0, bytes.length, 0);
      return;
    }
    final file = await PrivateMediaFiles().save(
      bytes,
      extension: (a['filename'] as String).split('.').last,
      expiresAt: attachmentDeadline(a),
    );
    try {
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
    } finally {
      bytes.fillRange(0, bytes.length, 0);
      if (await file.exists()) await file.delete();
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = attachment;
    if (visualAttachmentExpired(a, DateTime.now())) {
      return const Text('Media expired');
    }

    final isVisual = widget.kind == 'image' || widget.kind == 'video';
    final isAudio = widget.kind == 'audio' || widget.kind == 'voice';
    final isDocument = widget.kind == 'file';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (downloading) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(value: downloadProgress),
                ),
                if (downloadProgress != null && downloadProgress! > 0) ...[
                  const SizedBox(width: 8),
                  Text(
                    '${(downloadProgress! * 100).toInt()}%',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ],
            ),
          ),
        ],
        if (downloadFailed) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Icon(
                  Icons.error_outline,
                  size: 14,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 4),
                Text(
                  'Download failed',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
                const Spacer(),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () {
                    setState(() => downloadFailed = false);
                    act(context, isDocument ? openDocument : downloadAndShare);
                  },
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ],
        if (isVisual)
          ExpiringAttachmentView(
            key: ValueKey(a['media_expires_at']),
            client: widget.client,
            attachment: a,
            kind: widget.kind,
          ),
        if (isAudio)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (preparingAudio)
                      const Padding(
                        padding: EdgeInsets.all(10),
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else if (audioFailed)
                      IconButton(
                        tooltip: 'Retry audio',
                        icon: Icon(
                          Icons.refresh,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        onPressed: () => act(context, play),
                      )
                    else
                      IconButton(
                        tooltip: playing ? 'Pause' : 'Play',
                        onPressed: () => act(context, play),
                        icon: Icon(
                          playing
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                          size: 34,
                        ),
                      ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6,
                              ),
                            ),
                            child: Slider(
                              value: audioPosition.inMilliseconds
                                  .clamp(0, audioDuration.inMilliseconds)
                                  .toDouble(),
                              max: (audioDuration.inMilliseconds > 0
                                      ? audioDuration.inMilliseconds
                                      : 1)
                                  .toDouble(),
                              onChanged: player == null
                                  ? null
                                  : (val) {
                                      player?.seek(
                                        Duration(milliseconds: val.round()),
                                      );
                                    },
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _formatDuration(audioPosition),
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                                if (audioDuration > Duration.zero)
                                  Text(
                                    _formatDuration(audioDuration),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelSmall,
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                      onPressed: () {
                        final nextSpeed = speed == 1.0
                            ? 1.5
                            : (speed == 1.5 ? 2.0 : 1.0);
                        setState(() => speed = nextSpeed);
                        player?.setSpeed(nextSpeed);
                        try {
                          ref.read(deviceSettingsProvider)?.setVoicePlaybackSpeed(nextSpeed);
                        } catch (_) {}
                      },
                      child: Text(
                        speed == 1.0
                            ? '1×'
                            : (speed == 1.5 ? '1.5×' : '2×'),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                if (audioFailed)
                  Padding(
                    padding: const EdgeInsets.only(left: 12, bottom: 4),
                    child: Text(
                      'Playback failed. Tap retry.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 11,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (isDocument)
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: downloading ? null : () => act(context, openDocument),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
              decoration: BoxDecoration(
                border: Border.all(
                  color: Theme.of(context).dividerColor.withOpacity(0.3),
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    _fileIcon(a['filename']),
                    size: 32,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          a['filename'] ?? 'Document',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${((a['size_bytes'] as num? ?? 0) / 1024).ceil()} KB',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Open document',
                    icon: const Icon(Icons.open_in_new, size: 20),
                    onPressed: downloading
                        ? null
                        : () => act(context, openDocument),
                  ),
                ],
              ),
            ),
          )
        else
          Text(a['filename'], maxLines: 1, overflow: TextOverflow.ellipsis),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isDocument) ...[
              Text(
                '${((a['size_bytes'] as num) / 1024).ceil()} KB',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
            IconButton(
              tooltip: 'Download and share',
              icon: const Icon(Icons.ios_share, size: 18),
              onPressed: () => act(context, downloadAndShare),
            ),
          ],
        ),
      ],
    );
  }
}
