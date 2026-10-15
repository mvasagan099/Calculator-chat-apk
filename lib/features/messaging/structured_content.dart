import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/widgets/actions.dart';
import '../../providers/app_providers.dart';
import '../../models/message.dart';

class StructuredContent extends ConsumerWidget {
  const StructuredContent({super.key, required this.message});
  final ChatMessage message;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Map<String, dynamic> data;
    try {
      data = jsonDecode(message.body) as Map<String, dynamic>;
    } catch (_) {
      return const Text('Unsupported content');
    }
    if (message.kind == 'location') {
      final lat = data['latitude'], lon = data['longitude'];
      if (lat is! num || lon is! num || lat.abs() > 90 || lon.abs() > 180) {
        return const Text('Invalid location');
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.location_on_outlined),
              Text('Shared location'),
            ],
          ),
          Text('${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}'),
          TextButton(
            onPressed: () => act(context, () async {
              final uri = Uri.https('www.google.com', '/maps/search/', {
                'api': '1',
                'query': '$lat,$lon',
              });
              if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
                throw StateError('No maps application available');
              }
            }),
            child: const Text('Open map'),
          ),
        ],
      );
    }
    final id = data['id'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.contact_page_outlined),
        Text(
          '${data['name'] ?? 'Contact'}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        Text('@${data['username'] ?? ''}'),
        TextButton(
          onPressed: id is! String
              ? null
              : () => act(context, () async {
                  final client = ref.read(supabaseProvider);
                  final cid = await client.rpc(
                    'create_direct',
                    params: {'peer': id},
                  );
                  if (context.mounted) context.push('/chat/$cid');
                }),
          child: const Text('Message contact'),
        ),
      ],
    );
  }
}
