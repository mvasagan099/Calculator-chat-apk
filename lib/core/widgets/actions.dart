import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> act(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } catch (error) {
    if (!context.mounted) return;
    final message = switch (error) {
      AuthException e => e.message,
      PostgrestException e => e.message,
      FormatException e => e.message,
      StateError e => e.message,
      _ =>
        'Unable to complete this action. Check your connection and try again.',
    };
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message.toString())));
  }
}

Future<String?> askText(
  BuildContext context,
  String title, {
  String initial = '',
  bool secret = false,
  String? hint,
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        obscureText: secret,
        autocorrect: !secret,
        enableSuggestions: !secret,
        decoration: InputDecoration(hintText: hint),
        maxLines: secret ? 1 : 3,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  // Dialog transition may still use the controller; dispose after that frame.
  Future<void>.delayed(const Duration(milliseconds: 400), controller.dispose);
  return result;
}

class LoadError extends StatelessWidget {
  const LoadError({super.key, required this.retry});
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Could not load. Check your connection.'),
        TextButton(onPressed: retry, child: const Text('Retry')),
      ],
    ),
  );
}
