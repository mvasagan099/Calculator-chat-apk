import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../providers/app_providers.dart';
import '../../core/widgets/private_scaffold.dart';
import '../../core/widgets/actions.dart';
import 'call_initiator.dart';

// In-memory cache for fast lookups and offline profile display
final _offlineNameCache = <String, String>{};
final _offlineAvatarCache = <String, String>{};

class CallHistoryScreen extends ConsumerStatefulWidget {
  const CallHistoryScreen({super.key});
  @override
  ConsumerState<CallHistoryScreen> createState() => _CallHistoryScreenState();
}

class _CallHistoryScreenState extends ConsumerState<CallHistoryScreen> {
  late final Stream<List<Map<String, dynamic>>> _callsStream;
  StreamSubscription<List<Map<String, dynamic>>>? _conversationsSub;
  final Map<String, Map<String, dynamic>> _conversationMap = {};

  @override
  void initState() {
    super.initState();
    final messenger = ref.read(messengerProvider);
    final supabase = ref.read(supabaseProvider);

    // Keep conversation titles and avatars populated from messenger cache
    _conversationsSub = messenger.conversations().listen((convs) {
      if (mounted) {
        setState(() {
          for (final c in convs) {
            final id = c['id'] as String?;
            if (id != null) {
              _conversationMap[id] = c;
              if (c['title'] != null) {
                _offlineNameCache[id] = c['title'] as String;
              }
              if (c['avatar_path'] != null) {
                _offlineAvatarCache[id] = c['avatar_path'] as String;
              }
            }
          }
        });
      }
    });

    _callsStream = messenger.watch(
      ['calls', 'call_history', 'conversations'],
      () async {
        try {
          final res = await supabase
              .from('calls')
              .select('''
                *,
                call_history(outcome),
                caller:caller_id(id, display_name, avatar_path),
                conversations(
                  id,
                  kind,
                  groups(name, avatar_path),
                  conversation_members(
                    user_id,
                    profiles(id, display_name, avatar_path)
                  )
                )
              ''')
              .order('created_at', ascending: false)
              .limit(100);
          return (res as List).cast<Map<String, dynamic>>();
        } catch (_) {
          // Fallback if joined select is restricted or schema differs
          final res = await supabase
              .from('calls')
              .select('*,call_history(outcome)')
              .order('created_at', ascending: false)
              .limit(100);
          return (res as List).cast<Map<String, dynamic>>();
        }
      },
    );
  }

  @override
  void dispose() {
    _conversationsSub?.cancel();
    super.dispose();
  }

  ({String title, String? avatarPath, bool isGroup}) _resolveCallParty(
    Map<String, dynamic> call,
    String? myUid,
  ) {
    final cid = call['conversation_id'] as String?;
    final isGroup = call['group_call'] == true;

    // 1. Try joined data
    final conv = call['conversations'] as Map<String, dynamic>?;
    if (conv != null) {
      if (isGroup) {
        final groupName = conv['groups']?['name'] as String?;
        if (groupName != null && groupName.isNotEmpty) {
          if (cid != null) _offlineNameCache[cid] = groupName;
          return (title: groupName, avatarPath: conv['groups']?['avatar_path'] as String?, isGroup: true);
        }
      } else {
        final members = (conv['conversation_members'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
        for (final m in members) {
          if (m['user_id'] != myUid) {
            final prof = m['profiles'] as Map<String, dynamic>?;
            final name = prof?['display_name'] as String?;
            if (name != null && name.trim().isNotEmpty) {
              if (cid != null) _offlineNameCache[cid] = name.trim();
              final av = prof?['avatar_path'] as String?;
              if (cid != null && av != null) _offlineAvatarCache[cid] = av;
              return (title: name.trim(), avatarPath: av, isGroup: false);
            }
          }
        }
      }
    }

    // 2. Caller profile if incoming
    if (call['caller_id'] != myUid) {
      final caller = call['caller'] as Map<String, dynamic>?;
      final callerName = caller?['display_name'] as String? ?? call['caller_name'] as String?;
      if (callerName != null && callerName.trim().isNotEmpty) {
        final av = caller?['avatar_path'] as String?;
        if (cid != null) {
          _offlineNameCache[cid] = callerName.trim();
          if (av != null) _offlineAvatarCache[cid] = av;
        }
        return (title: callerName.trim(), avatarPath: av, isGroup: isGroup);
      }
    }

    // 3. Cached conversation map from messengerProvider
    if (cid != null && _conversationMap.containsKey(cid)) {
      final cached = _conversationMap[cid]!;
      final title = cached['title'] as String?;
      if (title != null && title.trim().isNotEmpty) {
        return (
          title: title.trim(),
          avatarPath: cached['avatar_path'] as String?,
          isGroup: isGroup || cached['kind'] == 'group',
        );
      }
    }

    // 4. Offline static cache
    if (cid != null && _offlineNameCache.containsKey(cid)) {
      return (
        title: _offlineNameCache[cid]!,
        avatarPath: _offlineAvatarCache[cid],
        isGroup: isGroup,
      );
    }

    return (
      title: isGroup ? 'Group Call' : 'Contact',
      avatarPath: null,
      isGroup: isGroup,
    );
  }

  String _getInitials(String name) {
    final clean = name.trim();
    if (clean.isEmpty) return '?';
    final parts = clean.split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      final first = parts[0].characters.firstOrNull ?? '';
      final second = parts[1].characters.firstOrNull ?? '';
      return (first + second).toUpperCase();
    }
    return clean.characters.take(2).toString().toUpperCase();
  }

  Widget _buildSkeletonLoading(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final baseColor = isDark ? Colors.white12 : Colors.black12;

    return ListView.separated(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: 8,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (_, _) => Padding(
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
      stream: _callsStream,
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
            final isOutgoing = c['caller_id'] == myUid;
            final outcome = (c['call_history'] as List?)?.firstOrNull?['outcome'] ?? c['state'];
            final isMissed = !isOutgoing && (outcome == 'missed' || outcome == 'rejected' || outcome == 'busy' || outcome == 'cancelled');

            final party = _resolveCallParty(c, myUid);
            final title = party.title;
            final initials = _getInitials(title);

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

            final callTypeLabel = isVideo ? 'Video' : 'Voice';
            final directionLabel = isOutgoing ? 'Outgoing' : (isMissed ? 'Missed' : 'Incoming');

            return InkWell(
              onTap: () => context.push('/call/${c['id']}'),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Stack(
                      children: [
                        CircleAvatar(
                          radius: 24,
                          backgroundColor: isMissed
                              ? theme.colorScheme.errorContainer
                              : (party.isGroup
                                  ? theme.colorScheme.secondaryContainer
                                  : theme.colorScheme.primaryContainer),
                          foregroundColor: isMissed
                              ? theme.colorScheme.onErrorContainer
                              : (party.isGroup
                                  ? theme.colorScheme.onSecondaryContainer
                                  : theme.colorScheme.onPrimaryContainer),
                          child: party.isGroup
                              ? const Icon(Icons.group_rounded, size: 24)
                              : Text(
                                  initials,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
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
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: isMissed ? theme.colorScheme.error : null,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Icon(
                                isVideo ? Icons.videocam_rounded : Icons.call_rounded,
                                size: 14,
                                color: statusColor,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '$directionLabel $callTypeLabel',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: statusColor,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              Flexible(
                                child: Text(
                                  ' · $formattedDate$durationLabel',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
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
