import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../providers/app_providers.dart';
import '../../core/widgets/private_scaffold.dart';
import '../../core/widgets/actions.dart';
import 'call_initiator.dart';

class CallHistoryScreen extends ConsumerStatefulWidget {
  const CallHistoryScreen({super.key});
  @override
  ConsumerState<CallHistoryScreen> createState() => _CallHistoryScreenState();
}

class _CallHistoryScreenState extends ConsumerState<CallHistoryScreen> {
  late final stream = ref.read(messengerProvider).watch(
    ['calls'],
    () async => await ref
        .read(supabaseProvider)
        .from('calls')
        .select('*,call_history(outcome)')
        .order('created_at', ascending: false)
        .limit(100),
  );

  Widget _buildSkeletonLoading(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final baseColor = isDark ? Colors.white12 : Colors.black12;

    return ListView.separated(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: 8,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (_, __) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: baseColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 140,
                    height: 14,
                    decoration: BoxDecoration(
                      color: baseColor,
                      borderRadius: BorderRadius.circular(7),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: 90,
                    height: 11,
                    decoration: BoxDecoration(
                      color: baseColor,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: baseColor,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 92,
              height: 92,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
              ),
              child: Icon(
                Icons.add_call,
                size: 44,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'No recent calls',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Private voice and video calls you make or receive will appear here.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PrivateScaffold(
    title: 'Calls',
    index: 2,
    body: StreamBuilder<List<Map<String, dynamic>>>(
      stream: stream,
      builder: (context, s) {
        if (s.hasError) return LoadError(retry: () => context.go('/calls'));
        if (!s.hasData) return _buildSkeletonLoading(context);
        final calls = s.data!;
        if (calls.isEmpty) return _buildEmptyState(context);

        final theme = Theme.of(context);
        final myUid = ref.read(supabaseProvider).auth.currentUser?.id;

        return ListView.builder(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 6),
          itemCount: calls.length,
          itemBuilder: (context, i) {
            final c = calls[i];
            final isVideo = c['video'] == true;
            final isGroup = c['group_call'] == true;
            final isOutgoing = c['caller_id'] == myUid;
            final outcome = (c['call_history'] as List?)?.firstOrNull?['outcome'] ?? c['state'];
            final isMissed = !isOutgoing && (outcome == 'missed' || outcome == 'rejected' || outcome == 'busy' || outcome == 'cancelled');

            IconData statusIcon;
            Color statusColor;
            if (isOutgoing) {
              statusIcon = Icons.call_made_rounded;
              statusColor = theme.colorScheme.primary;
            } else if (isMissed) {
              statusIcon = Icons.call_missed_rounded;
              statusColor = theme.colorScheme.error;
            } else {
              statusIcon = Icons.call_received_rounded;
              statusColor = Colors.green;
            }

            String durationLabel = '';
            if (c['answered_at'] != null && c['ended_at'] != null) {
              final dur = DateTime.parse(c['ended_at']).difference(DateTime.parse(c['answered_at']));
              final secs = dur.inSeconds.clamp(0, 7200);
              if (secs >= 60) {
                durationLabel = ' · ${dur.inMinutes}m ${secs % 60}s';
              } else {
                durationLabel = ' · ${secs}s';
              }
            }

            final createdAt = DateTime.tryParse(c['created_at'] ?? '')?.toLocal();
            final formattedDate = createdAt != null
                ? DateFormat.yMMMd().add_Hm().format(createdAt)
                : '';

            final callTypeTitle = isGroup
                ? (isVideo ? 'Group Video Call' : 'Group Voice Call')
                : (isVideo ? 'Video Call' : 'Voice Call');

            return InkWell(
              onTap: () => context.push('/call/${c['id']}'),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Stack(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: isMissed
                                ? theme.colorScheme.errorContainer.withValues(alpha: 0.5)
                                : theme.colorScheme.surfaceContainerHighest,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            isVideo ? Icons.videocam_rounded : Icons.call_rounded,
                            color: isMissed
                                ? theme.colorScheme.error
                                : theme.colorScheme.onSurfaceVariant,
                            size: 24,
                          ),
                        ),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surface,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(statusIcon, size: 14, color: statusColor),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            callTypeTitle,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: isMissed ? theme.colorScheme.error : null,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Text(
                                isOutgoing ? 'Outgoing' : (isMissed ? 'Missed' : 'Incoming'),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: statusColor,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              Text(
                                ' · $formattedDate$durationLabel',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: 'Call back',
                      icon: Icon(
                        isVideo ? Icons.videocam_rounded : Icons.call_rounded,
                        size: 20,
                      ),
                      onPressed: () => act(context, () async {
                        final id = await ref
                            .read(callInitiatorProvider)
                            .start(c['conversation_id'], isVideo);
                        if (context.mounted) context.push('/call/$id');
                      }),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ),
  );
}
