import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

class ParticipantGrid extends StatefulWidget {
  const ParticipantGrid({super.key, required this.room, required this.names});
  final Room? room;
  final Map<String, String> names;
  @override
  State<ParticipantGrid> createState() => _ParticipantGridState();
}

class _ParticipantGridState extends State<ParticipantGrid> {
  String? pinned;
  @override
  Widget build(BuildContext context) {
    final participants = <Participant>[
      if (widget.room?.localParticipant != null) widget.room!.localParticipant!,
      ...?widget.room?.remoteParticipants.values,
    ];
    if (participants.isEmpty) {
      return const Center(child: Icon(Icons.headset_mic_outlined, size: 96));
    }
    final focus = participants.where((p) => p.identity == pinned).firstOrNull;
    final visible = focus == null ? participants : [focus];
    return LayoutBuilder(
      builder: (context, constraints) => GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: visible.length == 1
              ? 1
              : constraints.maxWidth >= 700
              ? 3
              : 2,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: visible.length == 1
              ? constraints.maxWidth /
                    (constraints.maxHeight - 24).clamp(1, double.infinity)
              : .8,
        ),
        itemCount: visible.length,
        itemBuilder: (context, index) {
          final p = visible[index];
          final publications = p.videoTrackPublications.where(
            (pub) => !pub.muted && pub.track != null,
          );
          final publication =
              publications.where((pub) => pub.isScreenShare).firstOrNull ??
              publications.firstOrNull;
          final local = p is LocalParticipant;
          final user = p.identity.split(':').first;
          return Semantics(
            label:
                '${widget.names[user] ?? 'Participant'}${p.isSpeaking ? ', speaking' : ''}',
            child: InkWell(
              onTap: () => setState(
                () => pinned = pinned == p.identity ? null : p.identity,
              ),
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  border: Border.all(
                    width: p.isSpeaking ? 3 : 1,
                    color: p.isSpeaking
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (publication?.track != null)
                      VideoTrackRenderer(publication!.track! as VideoTrack)
                    else
                      const Center(child: Icon(Icons.person_outline, size: 72)),
                    Positioned(
                      left: 8,
                      right: 8,
                      bottom: 8,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Row(
                            children: [
                              Icon(
                                p.isMicrophoneEnabled()
                                    ? Icons.mic
                                    : Icons.mic_off,
                                color: Colors.white,
                                size: 16,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  local
                                      ? 'You'
                                      : widget.names[user] ?? 'Participant',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                              if (focus != null)
                                const Icon(
                                  Icons.push_pin,
                                  color: Colors.white,
                                  size: 16,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
