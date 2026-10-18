import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/widgets/actions.dart';
import '../../models/message.dart';
import '../../providers/app_providers.dart';

class PollWidget extends ConsumerWidget {
  const PollWidget({super.key, required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Map<String, dynamic> data;
    try {
      data = jsonDecode(message.body) as Map<String, dynamic>;
    } catch (_) {
      return const Text('Invalid poll content');
    }

    final question = data['question'] as String? ?? 'Poll';
    final options = (data['options'] as List? ?? []).cast<String>();
    final multiple = data['multiple'] == true;
    final votes = (data['votes'] as Map? ?? {}).cast<String, dynamic>();

    final myUid = ref.read(messengerProvider).uid;
    final mySelected = (votes[myUid] as List? ?? []).cast<int>().toSet();

    // Calculate votes per option
    final optionCounts = List<int>.filled(options.length, 0);
    var totalVotes = 0;
    final votingUsers = votes.keys.toSet();

    for (final userChoices in votes.values) {
      if (userChoices is List) {
        for (final choice in userChoices) {
          if (choice is int && choice >= 0 && choice < options.length) {
            optionCounts[choice]++;
            totalVotes++;
          }
        }
      }
    }

    final totalVoters = votingUsers.length;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.poll_outlined, size: 20, color: colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  question,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < options.length; i++) ...[
            _PollOptionTile(
              index: i,
              text: options[i],
              count: optionCounts[i],
              totalCount: totalVotes > 0 ? totalVotes : 1,
              hasVoted: totalVotes > 0,
              isSelected: mySelected.contains(i),
              isMultiple: multiple,
              onTap: () => act(context, () async {
                await ref.read(messengerProvider).votePoll(message.id, i);
              }),
            ),
            const SizedBox(height: 6),
          ],
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '$totalVoters ${totalVoters == 1 ? 'vote' : 'votes'} · ${multiple ? 'Multiple choices' : 'Single choice'}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PollOptionTile extends StatelessWidget {
  const _PollOptionTile({
    required this.index,
    required this.text,
    required this.count,
    required this.totalCount,
    required this.hasVoted,
    required this.isSelected,
    required this.isMultiple,
    required this.onTap,
  });

  final int index;
  final String text;
  final int count;
  final int totalCount;
  final bool hasVoted;
  final bool isSelected;
  final bool isMultiple;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final percentage = (count / totalCount).clamp(0.0, 1.0);
    final percentInt = (percentage * 100).round();

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected ? colorScheme.primary : theme.dividerColor.withValues(alpha: 0.3),
              width: isSelected ? 1.8 : 1.0,
            ),
          ),
          child: Stack(
            children: [
              // Progress fill bar behind text
              if (hasVoted && count > 0)
                Positioned.fill(
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: percentage,
                    child: Container(
                      decoration: BoxDecoration(
                        color: isSelected
                            ? colorScheme.primaryContainer.withValues(alpha: 0.5)
                            : colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      isMultiple
                          ? (isSelected ? Icons.check_box : Icons.check_box_outline_blank)
                          : (isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                      size: 20,
                      color: isSelected ? colorScheme.primary : theme.hintColor,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        text,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ),
                    if (hasVoted) ...[
                      const SizedBox(width: 6),
                      Text(
                        '$percentInt% ($count)',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: isSelected ? colorScheme.primary : null,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CreatePollDialog extends StatefulWidget {
  const CreatePollDialog({super.key});

  @override
  State<CreatePollDialog> createState() => _CreatePollDialogState();
}

class _CreatePollDialogState extends State<CreatePollDialog> {
  final questionController = TextEditingController();
  final optionControllers = [
    TextEditingController(),
    TextEditingController(),
  ];
  bool allowMultiple = false;

  @override
  void dispose() {
    questionController.dispose();
    for (final c in optionControllers) {
      c.dispose();
    }
    super.dispose();
  }

  void addOption() {
    if (optionControllers.length < 10) {
      setState(() {
        optionControllers.add(TextEditingController());
      });
    }
  }

  void removeOption(int index) {
    if (optionControllers.length > 2) {
      setState(() {
        final c = optionControllers.removeAt(index);
        c.dispose();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.poll),
          SizedBox(width: 8),
          Text('Create Poll'),
        ],
      ),
      content: SingleChildScrollView(
        child: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: questionController,
                decoration: const InputDecoration(
                  labelText: 'Question',
                  hintText: 'Ask a question...',
                  border: OutlineInputBorder(),
                ),
                maxLines: 2,
                minLines: 1,
              ),
              const SizedBox(height: 16),
              const Text(
                'Options',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < optionControllers.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: optionControllers[i],
                          decoration: InputDecoration(
                            hintText: 'Option ${i + 1}',
                            isDense: true,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                      if (optionControllers.length > 2)
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline, size: 20),
                          onPressed: () => removeOption(i),
                          tooltip: 'Remove option',
                        ),
                    ],
                  ),
                ),
              if (optionControllers.length < 10)
                TextButton.icon(
                  onPressed: addOption,
                  icon: const Icon(Icons.add),
                  label: const Text('Add option'),
                ),
              const Divider(),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Multiple answers'),
                subtitle: const Text('Allow voting for more than one option'),
                value: allowMultiple,
                onChanged: (v) => setState(() => allowMultiple = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final question = questionController.text.trim();
            final options = optionControllers
                .map((c) => c.text.trim())
                .where((t) => t.isNotEmpty)
                .toList();
            if (question.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Please enter a poll question')),
              );
              return;
            }
            if (options.length < 2) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Please provide at least 2 options')),
              );
              return;
            }
            Navigator.pop(context, {
              'question': question,
              'options': options,
              'multiple': allowMultiple,
            });
          },
          child: const Text('Create'),
        ),
      ],
    );
  }
}
