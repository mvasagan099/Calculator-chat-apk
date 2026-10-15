import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:go_router/go_router.dart';
import '../../core/widgets/actions.dart';
import '../../providers/app_providers.dart';
import 'call_controller.dart';

final callProvider = Provider<CallController>((ref) {
  final controller = CallController(ref.watch(supabaseProvider));
  ref.onDispose(controller.dispose);
  return controller;
});

class CallScreen extends ConsumerStatefulWidget {
  const CallScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends ConsumerState<CallScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (mounted) {
        act(context, () => ref.read(callProvider).observe(widget.id));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(callProvider);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final call = controller.metadata;
        final incoming =
            call?['caller_id'] !=
            ref.read(supabaseProvider).auth.currentUser?.id;
        final state = call?['state'] ?? 'Loading';
        final active = state == 'accepted';
        final remote = controller.room?.remoteParticipants.values.firstOrNull;
        final remoteVideo = remote?.videoTrackPublications
            .where((p) => p.subscribed && !p.muted)
            .firstOrNull
            ?.track;
        final localVideo = controller
            .room
            ?.localParticipant
            ?.videoTrackPublications
            .where((p) => !p.muted)
            .firstOrNull
            ?.track;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Private call'),
            actions: [
              IconButton(
                tooltip: 'Return to Calculator',
                onPressed: () => ref.read(lockProvider).lock(),
                icon: const Icon(Icons.calculate_outlined),
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                Text(
                  call?['video'] == true ? 'Video call' : 'Voice call',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                Text(
                  controller.reconnecting
                      ? 'Reconnecting…'
                      : controller.connecting
                      ? 'Connecting…'
                      : state == 'ringing'
                      ? (incoming ? 'Incoming call' : 'Ringing…')
                      : state,
                ),
                if (active)
                  Text(
                    '${controller.duration.inMinutes.toString().padLeft(2, '0')}:${(controller.duration.inSeconds % 60).toString().padLeft(2, '0')}',
                  ),
                if (controller.error != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(controller.error!),
                  ),
                if (active &&
                    controller.error != null &&
                    !controller.connecting)
                  TextButton.icon(
                    onPressed: () => act(context, controller.connect),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry connection'),
                  ),
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: remoteVideo != null
                            ? VideoTrackRenderer(remoteVideo)
                            : Center(
                                child: Icon(
                                  Icons.person,
                                  size: 120,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                      ),
                      if (localVideo != null)
                        Positioned(
                          right: 16,
                          bottom: 16,
                          width: 110,
                          height: 160,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(18),
                            child: VideoTrackRenderer(localVideo),
                          ),
                        ),
                      if (remote != null)
                        Positioned(
                          left: 16,
                          top: 16,
                          child: Chip(
                            label: Text(
                              'Connection: ${remote.connectionQuality.name}',
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (state == 'ringing' && incoming)
                  Wrap(
                    spacing: 24,
                    children: [
                      FilledButton.icon(
                        onPressed: () => act(context, controller.accept),
                        icon: const Icon(Icons.call),
                        label: const Text('Answer'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () => act(context, controller.reject),
                        icon: const Icon(Icons.call_end),
                        label: const Text('Reject'),
                      ),
                    ],
                  )
                else if (active)
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    children: [
                      IconButton.filledTonal(
                        tooltip: controller.mic ? 'Mute' : 'Unmute',
                        onPressed: () => act(context, controller.toggleMic),
                        icon: Icon(controller.mic ? Icons.mic : Icons.mic_off),
                      ),
                      IconButton.filledTonal(
                        tooltip: 'Speaker',
                        onPressed: () => act(context, controller.toggleSpeaker),
                        icon: Icon(
                          controller.speaker ? Icons.volume_up : Icons.hearing,
                        ),
                      ),
                      if (call?['video'] == true) ...[
                        IconButton.filledTonal(
                          tooltip: 'Camera',
                          onPressed: () =>
                              act(context, controller.toggleCamera),
                          icon: Icon(
                            controller.camera
                                ? Icons.videocam
                                : Icons.videocam_off,
                          ),
                        ),
                        IconButton.filledTonal(
                          tooltip: 'Switch camera',
                          onPressed: () =>
                              act(context, controller.switchCamera),
                          icon: const Icon(Icons.cameraswitch),
                        ),
                      ],
                      IconButton.filledTonal(
                        tooltip: 'Audio output / Bluetooth',
                        onPressed: () => act(context, () async {
                          final devices = await Hardware.instance
                              .audioOutputs();
                          if (!context.mounted) return;
                          final selected =
                              await showModalBottomSheet<MediaDevice>(
                                context: context,
                                builder: (c) => SafeArea(
                                  child: ListView(
                                    shrinkWrap: true,
                                    children: [
                                      for (final device in devices)
                                        ListTile(
                                          title: Text(device.label),
                                          onTap: () => Navigator.pop(c, device),
                                        ),
                                    ],
                                  ),
                                ),
                              );
                          if (selected != null) {
                            await Hardware.instance.selectAudioOutput(selected);
                          }
                        }),
                        icon: const Icon(Icons.bluetooth_audio),
                      ),
                    ],
                  ),
                const SizedBox(height: 16),
                if (['ringing', 'accepted'].contains(state))
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                    ),
                    onPressed: () => act(context, controller.end),
                    icon: const Icon(Icons.call_end),
                    label: const Text('End call'),
                  )
                else
                  TextButton(
                    onPressed: () async {
                      await controller.reset();
                      if (context.mounted) context.go('/calls');
                    },
                    child: const Text('Back to calls'),
                  ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        );
      },
    );
  }
}
