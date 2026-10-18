import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:go_router/go_router.dart';
import '../../core/widgets/actions.dart';
import '../../providers/app_providers.dart';
import 'call_controller.dart';
import 'call_transport.dart';
import 'participant_grid.dart';
import 'network_panel.dart';
import 'call_waiting_panel.dart';

final callProvider = Provider<CallController>((ref) {
  final controller = CallController(ref.watch(supabaseProvider));
  final lock = ref.watch(lockProvider);
  void locked() {
    if (!lock.unlocked) {
      controller.stopSharing().catchError((Object _) {});
      controller.handleRelock().catchError((Object _) {});
    }
  }

  final auth = ref.watch(authServiceProvider);
  void authorizationChanged() {
    if (auth != null &&
        (!auth.signedIn || !auth.deviceAuthorized || !auth.ownerMatches)) {
      controller.reset().catchError((Object _) {});
    }
  }

  auth?.addListener(authorizationChanged);
  lock.addListener(locked);
  ref.onDispose(() {
    lock.removeListener(locked);
    auth?.removeListener(authorizationChanged);
    controller.dispose();
  });
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
  void didUpdateWidget(covariant CallScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) {
      Future.microtask(() {
        if (mounted) {
          act(context, () => ref.read(callProvider).observe(widget.id));
        }
      });
    }
  }

  Future<void> showParticipants(
    CallController controller,
    List<Map<String, dynamic>> participants,
  ) async {
    final client = ref.read(supabaseProvider);
    final id = controller.callId;
    if (id == null) return;
    final members = await client
        .from('conversation_members')
        .select('user_id,profiles(display_name)')
        .eq('conversation_id', controller.metadata!['conversation_id']);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('Group call participants'),
              subtitle: Text('Only current, eligible group members can join.'),
            ),
            for (final member in members)
              ListTile(
                title: Text(
                  member['profiles']?['display_name'] ?? 'Participant',
                ),
                subtitle: Text(
                  participants
                          .where((p) => p['user_id'] == member['user_id'])
                          .firstOrNull?['state'] ??
                      'Not invited',
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (action) {
                    Navigator.pop(sheet);
                    act(context, () async {
                      final response = await client.functions.invoke(
                        'call-control',
                        body: {
                          'call_id': id,
                          'action': action,
                          'person': member['user_id'],
                        },
                      );
                      if (response.status != 200) {
                        throw StateError('Participant operation unavailable');
                      }
                    });
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'invite',
                      child: Text('Invite / ring again'),
                    ),
                    if (controller.metadata?['caller_id'] ==
                        client.auth.currentUser?.id)
                      const PopupMenuItem(
                        value: 'remove',
                        child: Text('Remove from call'),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(callProvider);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.callId != null &&
            controller.callId != widget.id &&
            !controller.finished) {
          return Scaffold(
            appBar: AppBar(title: const Text('Call waiting')),
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Another call is active on this device.'),
                  FilledButton(
                    onPressed: () => act(context, () async {
                      await controller.end();
                      await controller.reset();
                      await controller.observe(widget.id);
                    }),
                    child: const Text('End current and review incoming call'),
                  ),
                  TextButton(
                    onPressed: () => act(context, () async {
                      final result = await ref
                          .read(supabaseProvider)
                          .functions
                          .invoke(
                            'call-control',
                            body: {'call_id': widget.id, 'action': 'busy'},
                          );
                      if (result.status != 200) {
                        throw StateError('Call update unavailable');
                      }
                      if (context.mounted) {
                        context.go('/call/${controller.callId}');
                      }
                    }),
                    child: const Text('Decline waiting call'),
                  ),
                  TextButton(
                    onPressed: () => context.go('/call/${controller.callId}'),
                    child: const Text('Keep current call'),
                  ),
                ],
              ),
            ),
          );
        }
        final call = controller.metadata;
        final incoming =
            call?['caller_id'] !=
            ref.read(supabaseProvider).auth.currentUser?.id;
        final state = call?['state'] ?? 'Loading';
        final active =
            state == 'accepted' && controller.joined && !controller.finished;
        final participants = (call?['participants'] as List? ?? [])
            .cast<Map<String, dynamic>>();
        final names = {
          for (final p in participants)
            p['user_id'] as String:
                p['display_name'] as String? ?? 'Participant',
        };
        final needsAnswer =
            !controller.finished &&
            (call?['self_state'] == 'invited' ||
                (state == 'ringing' && incoming));
        final canRejoin =
            call?['group_call'] == true &&
            call?['self_state'] == 'left' &&
            state == 'accepted';
        if (controller.inPip) {
          return Scaffold(
            backgroundColor: Colors.black,
            body: SafeArea(
              child: Center(
                child: ParticipantGrid(
                  room: controller.room,
                  names: names,
                ),
              ),
            ),
          );
        }
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
                CallWaitingPanel(current: widget.id, controller: controller),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    children: [
                      Text(
                        '${call?['group_call'] == true ? 'Group ' : ''}${call?['video'] == true ? 'Video call' : 'Voice call'}',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                        decoration: BoxDecoration(
                          color: (active ? Colors.green : Theme.of(context).colorScheme.primaryContainer).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: active
                                    ? Colors.green
                                    : (controller.connecting || controller.reconnecting
                                        ? Colors.amber
                                        : Theme.of(context).colorScheme.primary),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              active
                                  ? '${controller.duration.inMinutes.toString().padLeft(2, '0')}:${(controller.duration.inSeconds % 60).toString().padLeft(2, '0')}'
                                  : (controller.reconnecting
                                      ? 'Reconnecting…'
                                      : controller.connecting
                                      ? 'Connecting…'
                                      : state == 'ringing'
                                      ? (incoming ? 'Incoming call…' : 'Ringing…')
                                      : state),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                fontFeatures: const [FontFeature.tabularFigures()],
                                color: active ? Colors.green : Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (active) CallNetworkPanel(room: controller.room),
                if (controller.sharing)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Chip(
                      avatar: Icon(Icons.screen_share, size: 16),
                      label: Text('Screen sharing is active'),
                    ),
                  ),
                if (controller.hasPendingEnd)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Call ended on this device. Retrying server update…',
                    ),
                  ),
                if (controller.error != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(controller.error!),
                  ),
                if (active &&
                    controller.error != null &&
                    !controller.connecting &&
                    controller.room == null)
                  TextButton.icon(
                    onPressed: () => act(context, controller.connect),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry connection'),
                  ),
                Expanded(
                  child: active
                      ? ParticipantGrid(room: controller.room, names: names)
                      : ListView(
                          children: [
                            for (final p in participants)
                              ListTile(
                                leading: const Icon(Icons.person_outline),
                                title: Text(p['display_name'] ?? 'Participant'),
                                subtitle: Text(p['state'] ?? ''),
                              ),
                          ],
                        ),
                ),
                if (canRejoin)
                  FilledButton.icon(
                    onPressed: () => act(context, controller.accept),
                    icon: const Icon(Icons.login),
                    label: const Text('Rejoin call'),
                  ),
                if (needsAnswer)
                  Wrap(
                    spacing: 24,
                    children: [
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                        ),
                        onPressed: () => act(context, controller.accept),
                        icon: const Icon(Icons.call),
                        label: const Text('Answer'),
                      ),
                      FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.errorContainer,
                          foregroundColor: Theme.of(context).colorScheme.error,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                        ),
                        onPressed: () => act(context, controller.reject),
                        icon: const Icon(Icons.call_end),
                        label: const Text('Reject'),
                      ),
                    ],
                  )
                else if (active)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        IconButton.filledTonal(
                          style: !controller.mic ? IconButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.errorContainer) : null,
                          tooltip: controller.mic ? 'Mute' : 'Unmute',
                          onPressed: () => act(context, controller.toggleMic),
                          icon: Icon(
                            controller.mic ? Icons.mic : Icons.mic_off,
                            color: !controller.mic ? Theme.of(context).colorScheme.error : null,
                          ),
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
                            style: !controller.camera ? IconButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.errorContainer) : null,
                            tooltip: 'Camera',
                            onPressed: () =>
                                act(context, controller.toggleCamera),
                            icon: Icon(
                              controller.camera
                                  ? Icons.videocam
                                  : Icons.videocam_off,
                              color: !controller.camera ? Theme.of(context).colorScheme.error : null,
                            ),
                          ),
                          IconButton.filledTonal(
                            tooltip: 'Switch camera',
                            onPressed: () =>
                                act(context, controller.switchCamera),
                            icon: const Icon(Icons.cameraswitch),
                          ),
                        ],
                        if (call?['video'] == true) ...[
                          IconButton.filledTonal(
                            tooltip: controller.sharing
                                ? 'Stop sharing'
                                : 'Share screen',
                            onPressed: () => act(
                              context,
                              () => controller.toggleSharing(
                                ref.read(lockProvider).projectionConsent,
                              ),
                            ),
                            icon: Icon(
                              controller.sharing
                                  ? Icons.stop_screen_share
                                  : Icons.screen_share,
                            ),
                          ),
                          IconButton.filledTonal(
                            tooltip: controller.audioOnly
                                ? 'Receive video'
                                : 'Audio-only fallback',
                            onPressed: () =>
                                act(context, controller.toggleAudioOnly),
                            icon: Icon(
                              controller.audioOnly
                                  ? Icons.video_call
                                  : Icons.headphones,
                            ),
                          ),
                          if (active && call?['video'] == true)
                            IconButton.filledTonal(
                              tooltip: 'Picture-in-picture',
                              onPressed: () => act(context, controller.enterPip),
                              icon: const Icon(Icons.picture_in_picture_alt),
                            ),
                        ],
                        if (call?['group_call'] == true)
                          IconButton.filledTonal(
                            tooltip: 'Participants and invitations',
                            onPressed: () => act(
                              context,
                              () => showParticipants(controller, participants),
                            ),
                            icon: const Icon(Icons.group_add_outlined),
                          ),
                        IconButton.filledTonal(
                          tooltip: 'Audio output / Bluetooth',
                          onPressed: () => act(context, () async {
                            await AndroidCallDevice.bluetoothPermission();
                            if (!context.mounted) return;
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
                  ),
                const SizedBox(height: 8),
                if (!controller.finished &&
                    ['ringing', 'accepted'].contains(state) &&
                    !needsAnswer &&
                    !canRejoin)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.error,
                        foregroundColor: Theme.of(context).colorScheme.onError,
                        padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                      ),
                      onPressed: () => act(context, controller.end),
                      icon: const Icon(Icons.call_end),
                      label: Text(
                        call?['group_call'] == true
                            ? 'Leave call'
                            : state == 'ringing'
                            ? 'Cancel call'
                            : 'End call',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  )
                else
                  TextButton(
                    onPressed: () async {
                      await controller.reset();
                      if (context.mounted) context.go('/calls');
                    },
                    child: const Text('Back to calls'),
                  ),
                if (active &&
                    call?['group_call'] == true &&
                    call?['caller_id'] ==
                        ref.read(supabaseProvider).auth.currentUser?.id)
                  TextButton(
                    onPressed: () => act(context, controller.endForAll),
                    child: const Text('End for everyone'),
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
