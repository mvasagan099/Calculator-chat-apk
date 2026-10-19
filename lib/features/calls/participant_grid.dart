import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

enum PipCorner { topLeft, topRight, bottomLeft, bottomRight }

class ParticipantGrid extends StatefulWidget {
  const ParticipantGrid({
    super.key,
    required this.room,
    required this.names,
    this.onTapBackground,
  });

  final Room? room;
  final Map<String, String> names;
  final VoidCallback? onTapBackground;

  @override
  State<ParticipantGrid> createState() => _ParticipantGridState();
}

class _ParticipantGridState extends State<ParticipantGrid> {
  String? pinned;
  bool _isSwapped = false;
  PipCorner _pipCorner = PipCorner.bottomRight;
  Offset? _dragOffset;

  @override
  Widget build(BuildContext context) {
    final local = widget.room?.localParticipant;
    final remotes = widget.room?.remoteParticipants.values.toList() ?? [];
    final allParticipants = <Participant>[
      ?local,
      ...remotes,
    ];

    if (allParticipants.isEmpty) {
      return const Center(
        child: Icon(Icons.headset_mic_outlined, size: 96, color: Colors.white54),
      );
    }

    // 1:1 Video Call Layout with Picture-in-Picture & Tap-to-Swap
    if (remotes.length == 1 && local != null) {
      final remote = remotes.first;
      final Participant primary = _isSwapped ? local : remote;
      final Participant pip = _isSwapped ? remote : local;

      return LayoutBuilder(
        builder: (context, constraints) {
          final pipWidth = (constraints.maxWidth * 0.28).clamp(96.0, 140.0);
          final pipHeight = pipWidth * 1.35;
          const margin = 16.0;

          final maxLeft = (constraints.maxWidth - pipWidth - margin).clamp(margin, double.infinity);
          final maxTop = (constraints.maxHeight - pipHeight - margin).clamp(margin, double.infinity);

          Offset cornerOffset;
          switch (_pipCorner) {
            case PipCorner.topLeft:
              cornerOffset = const Offset(margin, margin);
              break;
            case PipCorner.topRight:
              cornerOffset = Offset(maxLeft, margin);
              break;
            case PipCorner.bottomLeft:
              cornerOffset = Offset(margin, maxTop);
              break;
            case PipCorner.bottomRight:
              cornerOffset = Offset(maxLeft, maxTop);
              break;
          }

          final pipPos = _dragOffset ?? cornerOffset;

          return Stack(
            fit: StackFit.expand,
            children: [
              // Full-screen Primary Participant Feed
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onTapBackground,
                child: _buildParticipantView(primary, isPip: false, context: context),
              ),

              // Floating Draggable Picture-in-Picture Feed
              Positioned(
                left: pipPos.dx.clamp(margin, maxLeft),
                top: pipPos.dy.clamp(margin, maxTop),
                width: pipWidth,
                height: pipHeight,
                child: GestureDetector(
                  onPanUpdate: (details) {
                    setState(() {
                      final current = _dragOffset ?? cornerOffset;
                      _dragOffset = Offset(
                        (current.dx + details.delta.dx).clamp(margin, maxLeft),
                        (current.dy + details.delta.dy).clamp(margin, maxTop),
                      );
                    });
                  },
                  onPanEnd: (_) {
                    if (_dragOffset != null) {
                      final midX = constraints.maxWidth / 2;
                      final midY = constraints.maxHeight / 2;
                      setState(() {
                        if (_dragOffset!.dx < midX) {
                          _pipCorner = _dragOffset!.dy < midY
                              ? PipCorner.topLeft
                              : PipCorner.bottomLeft;
                        } else {
                          _pipCorner = _dragOffset!.dy < midY
                              ? PipCorner.topRight
                              : PipCorner.bottomRight;
                        }
                        _dragOffset = null;
                      });
                    }
                  },
                  onTap: () {
                    setState(() {
                      _isSwapped = !_isSwapped;
                    });
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black54,
                          blurRadius: 10,
                          spreadRadius: 2,
                          offset: Offset(0, 4),
                        ),
                      ],
                      border: Border.all(color: Colors.white30, width: 1.5),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: _buildParticipantView(pip, isPip: true, context: context),
                        ),
                        // Swap hint pill in PIP
                        Positioned(
                          right: 6,
                          top: 6,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.swap_horiz_rounded,
                              color: Colors.white,
                              size: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
    }

    // Group / Multi-participant Responsive Grid Layout
    final focus = allParticipants.where((p) => p.identity == pinned).firstOrNull;
    final visible = focus == null ? allParticipants : [focus];

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
                  (constraints.maxHeight - 24).clamp(1.0, double.infinity)
              : 0.8,
        ),
        itemCount: visible.length,
        itemBuilder: (context, index) {
          final p = visible[index];
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
                    _buildParticipantView(p, isPip: false, context: context),
                    if (focus != null)
                      const Positioned(
                        top: 8,
                        right: 8,
                        child: Icon(
                          Icons.push_pin,
                          color: Colors.white,
                          size: 18,
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

  Widget _buildParticipantView(
    Participant p, {
    required bool isPip,
    required BuildContext context,
  }) {
    final publications = p.videoTrackPublications.where(
      (pub) => !pub.muted && pub.track != null,
    );
    final publication =
        publications.where((pub) => pub.isScreenShare).firstOrNull ??
        publications.firstOrNull;
    final isLocal = p is LocalParticipant;
    final user = p.identity.split(':').first;
    final name = isLocal ? 'You' : (widget.names[user] ?? 'Participant');
    final track = publication?.track as VideoTrack?;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (track != null)
          VideoTrackRenderer(track)
        else
          _buildAvatarFallback(name, p.isSpeaking, isPip, context),

        // Participant status banner at bottom
        Positioned(
          left: 6,
          right: 6,
          bottom: 6,
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: isPip ? 6 : 8,
              vertical: isPip ? 2 : 4,
            ),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  p.isMicrophoneEnabled() ? Icons.mic : Icons.mic_off,
                  color: p.isMicrophoneEnabled() ? Colors.white : Colors.redAccent,
                  size: isPip ? 11 : 14,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: isPip ? 10 : 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAvatarFallback(
    String name,
    bool isSpeaking,
    bool isPip,
    BuildContext context,
  ) {
    final clean = name.trim();
    final initials = clean.isEmpty
        ? '?'
        : clean
            .split(RegExp(r'\s+'))
            .take(2)
            .map((s) => s.isNotEmpty ? s[0].toUpperCase() : '')
            .join();
    final theme = Theme.of(context);

    return Container(
      color: Colors.black87,
      alignment: Alignment.center,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: EdgeInsets.all(isSpeaking ? (isPip ? 3.0 : 6.0) : 0),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: isSpeaking
              ? Border.all(
                  color: theme.colorScheme.primary,
                  width: isPip ? 2.0 : 3.5,
                )
              : null,
        ),
        child: CircleAvatar(
          radius: isPip ? 20.0 : 44.0,
          backgroundColor: theme.colorScheme.primaryContainer,
          foregroundColor: theme.colorScheme.onPrimaryContainer,
          child: Text(
            initials,
            style: TextStyle(
              fontSize: isPip ? 14 : 28,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}
