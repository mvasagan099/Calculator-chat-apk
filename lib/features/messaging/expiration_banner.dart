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
        ref.read(messengerProvider).rememberExpiration(widget.cid, seconds);
      }
      return ListTile(
        dense: true,
        leading: const Icon(Icons.timer_outlined, size: 20),
        title: Text(
          seconds == null
              ? 'Message expiration unavailable'
              : 'Disappearing messages · ${expirationLabel(seconds)}',
        ),
        subtitle: seconds != null && seconds > 0
            ? const Text(
                'Applies to new messages. Copies outside this app may remain.',
              )
            : null,
        trailing: widget.canChange
            ? PopupMenuButton<int>(
                tooltip: 'Set message expiration',
                itemBuilder: (_) => [
                  for (final value in [0, 86400, 604800, 2592000])
                    PopupMenuItem(
                      value: value,
                      child: Text(expirationLabel(value)),
                    ),
                ],
                onSelected: (value) => act(context, () async {
                  await ref
                      .read(supabaseProvider)
                      .rpc(
                        'set_disappearing_policy',
                        params: {'cid': widget.cid, 'seconds': value},
                      );
                }),
              )
            : null,
      );
    },
  );
}
