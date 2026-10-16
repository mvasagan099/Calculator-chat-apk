import 'dart:async';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

/// Actual SDK measurements only; absent values stay unavailable.
class CallNetworkPanel extends StatefulWidget {
  const CallNetworkPanel({super.key, required this.room});
  final Room? room;
  @override
  State<CallNetworkPanel> createState() => _CallNetworkPanelState();
}

class _CallNetworkPanelState extends State<CallNetworkPanel> {
  Timer? timer;
  bool reading = false;
  String details = '';
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 5), (_) => sample());
  }

  Future<void> sample() async {
    if (reading) return;
    final room = widget.room;
    if (room == null) return;
    reading = true;
    try {
      final videos = room.remoteParticipants.values
          .expand((p) => p.videoTrackPublications)
          .map((p) => p.track)
          .whereType<RemoteVideoTrack>();
      final track = videos.firstOrNull;
      final stats = await track?.getReceiverStats();
      final audio = room.localParticipant?.audioTrackPublications
          .map((p) => p.track)
          .whereType<LocalAudioTrack>()
          .firstOrNull;
      final send = await audio?.getSenderStats();
      if (mounted && identical(room, widget.room)) {
        setState(
          () => details = stats == null && send?.roundTripTime == null
              ? ''
              : 'RTT ${send?.roundTripTime == null ? '—' : '${(send!.roundTripTime! * 1000).round()} ms'} · video jitter ${stats?.jitter == null ? '—' : '${(stats!.jitter! * 1000).round()} ms'} · lost ${stats?.packetsLost ?? '—'} packets · ${track?.currentBitrate == null ? '—' : '${(track!.currentBitrate! / 1000).round()} kb/s'}',
        );
      }
    } catch (_) {
      if (mounted) setState(() => details = '');
    } finally {
      reading = false;
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(
        'Network: ${widget.room?.localParticipant?.connectionQuality.name ?? 'unavailable'}',
        style: Theme.of(context).textTheme.labelLarge,
      ),
      if (details.isNotEmpty)
        Text(
          details,
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
    ],
  );
}
