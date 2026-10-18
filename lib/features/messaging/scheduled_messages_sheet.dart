import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../core/widgets/actions.dart';
import '../../providers/app_providers.dart';

class ScheduledMessagesSheet extends ConsumerWidget {
  const ScheduledMessagesSheet({super.key, required this.conversationId});
  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messenger = ref.watch(messengerProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.schedule_send),
                  const SizedBox(width: 8),
                  Text(
                    'Scheduled messages',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(),
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: messenger.scheduledMessages(conversationId),
              builder: (context, snapshot) {
                final list = snapshot.data ?? [];
                if (list.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: Text('No scheduled messages for this conversation.'),
                    ),
                  );
                }

                return ListView.separated(
                  shrinkWrap: true,
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final item = list[i];
                    final scheduledFor = DateTime.tryParse(item['scheduled_for'] ?? '')?.toLocal();
                    final formattedDate = scheduledFor != null
                        ? DateFormat.yMMMd().add_jm().format(scheduledFor)
                        : 'Scheduled';

                    return ListTile(
                      leading: const CircleAvatar(
                        child: Icon(Icons.access_time, size: 20),
                      ),
                      title: Text(
                        item['body'] as String? ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        'Will send: $formattedDate',
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.send, size: 20),
                            tooltip: 'Send now',
                            onPressed: () => act(context, () async {
                              await messenger.send(
                                conversationId,
                                item['body'] as String,
                                kind: item['kind'] as String? ?? 'text',
                              );
                              await messenger.cancelScheduledMessage(item['id'] as String);
                            }),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20),
                            tooltip: 'Cancel',
                            onPressed: () => act(context, () async {
                              await messenger.cancelScheduledMessage(item['id'] as String);
                            }),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class ScheduleMessageDialog extends StatefulWidget {
  const ScheduleMessageDialog({super.key});

  @override
  State<ScheduleMessageDialog> createState() => _ScheduleMessageDialogState();
}

class _ScheduleMessageDialogState extends State<ScheduleMessageDialog> {
  DateTime selectedDate = DateTime.now().add(const Duration(hours: 1));
  TimeOfDay selectedTime = TimeOfDay.fromDateTime(DateTime.now().add(const Duration(hours: 1)));

  DateTime get scheduledDateTime => DateTime(
    selectedDate.year,
    selectedDate.month,
    selectedDate.day,
    selectedTime.hour,
    selectedTime.minute,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isFuture = scheduledDateTime.isAfter(DateTime.now().add(const Duration(minutes: 1)));

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.schedule),
          SizedBox(width: 8),
          Text('Schedule message'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.calendar_today),
            title: const Text('Date'),
            subtitle: Text(DateFormat.yMMMd().format(selectedDate)),
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: selectedDate,
                firstDate: DateTime.now(),
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (picked != null) {
                setState(() => selectedDate = picked);
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.access_time),
            title: const Text('Time'),
            subtitle: Text(selectedTime.format(context)),
            onTap: () async {
              final picked = await showTimePicker(
                context: context,
                initialTime: selectedTime,
              );
              if (picked != null) {
                setState(() => selectedTime = picked);
              }
            },
          ),
          if (!isFuture)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Please select a time in the future',
                style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: isFuture ? () => Navigator.pop(context, scheduledDateTime) : null,
          child: const Text('Schedule'),
        ),
      ],
    );
  }
}
