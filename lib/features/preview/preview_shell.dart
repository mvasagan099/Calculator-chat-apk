import 'package:flutter/material.dart';
import '../../core/widgets/private_scaffold.dart';

class PreviewShell extends StatelessWidget {
  const PreviewShell({
    super.key,
    required this.title,
    required this.index,
    required this.child,
    this.actions = const [],
    this.floatingActionButton,
  });
  final String title;
  final int index;
  final Widget child;
  final List<Widget> actions;
  final Widget? floatingActionButton;
  @override
  Widget build(BuildContext context) => PrivateScaffold(
    title: title,
    index: index,
    actions: actions,
    floatingActionButton: floatingActionButton,
    body: Column(
      children: [
        const PreviewNotice(),
        Expanded(child: child),
      ],
    ),
  );
}

class PreviewNotice extends StatelessWidget {
  const PreviewNotice({super.key});
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: Theme.of(context).colorScheme.secondaryContainer,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: const Text(
      'LOCAL PREVIEW · Sample data · No messages or calls are sent',
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    ),
  );
}

class PreviewAvatar extends StatelessWidget {
  const PreviewAvatar({
    super.key,
    required this.name,
    required this.color,
    this.radius = 25,
  });
  final String name;
  final int color;
  final double radius;
  @override
  Widget build(BuildContext context) => CircleAvatar(
    radius: radius,
    backgroundColor: Color(color),
    foregroundColor: Colors.white,
    child: Text(
      name.split(' ').take(2).map((part) => part.characters.first).join(),
      style: TextStyle(fontSize: radius * .62, fontWeight: FontWeight.w600),
    ),
  );
}
