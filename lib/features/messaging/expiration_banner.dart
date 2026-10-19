import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/app_providers.dart';
import '../../core/widgets/actions.dart';

String expirationLabel(int seconds) => switch (seconds) {
  0 => 'Off',
  86400 => '24 hours',
  604800 => '7 days',
  2592000 => '30 days',
  _ => '${seconds ~/ 60} minutes',
};

class ExpirationBanner extends ConsumerStatefulWidget {
  const ExpirationBanner({
    super.key,
    required this.cid,
    required this.canChange,
  });
  final String cid;
  final bool canChange;
  @override
  ConsumerState<ExpirationBanner> createState() => _ExpirationBannerState();
}

class _ExpirationBannerState extends ConsumerState<ExpirationBanner> {
  late final stream = ref.read(messengerProvider).watch(
    ['conversations'],
    () async {
      await ref.read(messengerProvider).prepare();
      return await ref
          .read(supabaseProvider)
          .from('conversations')
          .select('disappearing_seconds')
          .eq('id', widget.cid)
          .single();
    },
  );
  @override
  Widget build(BuildContext context) => StreamBuilder<Map<String, dynamic>>(
    stream: stream,
    builder: (context, snapshot) {
      final seconds = snapshot.data?['disappearing_seconds'] as int?;
      if (seconds != null) {
        // Preserve the local expiry policy used by offline messages.
        ref.read(messengerProvider).rememberExpiration(widget.cid, seconds);
      }
      final status = seconds == null ? 'Unavailable' : expirationLabel(seconds);
      return PopupMenuButton<int>(
        tooltip: 'Disappearing messages: $status',
        icon: Icon(
          Icons.timer_outlined,
          color: seconds != null && seconds > 0
              ? Theme.of(context).colorScheme.primary
              : null,
        ),
        itemBuilder: (_) => [
          PopupMenuItem<int>(
            enabled: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Disappearing messages',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text('Current: $status'),
                const SizedBox(height: 4),
                const Text('Applies to new messages. Copies outside this app may remain.'),
                if (!widget.canChange)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text('Only permitted participants can change this setting.'),
                  ),
              ],
            ),
          ),
          const PopupMenuDivider(),
          for (final value in [0, 86400, 604800, 2592000])
            PopupMenuItem<int>(
              value: value,
              enabled: widget.canChange && seconds != null,
              child: Row(
                children: [
                  Expanded(child: Text(expirationLabel(value))),
                  if (seconds == value) const Icon(Icons.check, size: 18),
                ],
              ),
            ),
        ],
        onSelected: (value) => act(context, () async {
          await ref.read(supabaseProvider).rpc(
            'set_disappearing_policy',
            params: {'cid': widget.cid, 'seconds': value},
          );
        }),
      );
    },
  );
}
