import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'app_update.dart';

class AppUpdateDialog extends StatelessWidget {
  const AppUpdateDialog({
    super.key,
    required this.update,
    this.onRemindLater,
  });

  final VerifiedAppUpdate update;
  final VoidCallback? onRemindLater;

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sizeStr = _formatBytes(update.apkSizeBytes);

    return PopScope(
      canPop: !update.isUnsupported,
      child: AlertDialog(
        icon: Icon(
          update.isUnsupported ? Icons.security_update_warning : Icons.system_update_outlined,
          size: 40,
          color: update.isUnsupported ? Colors.amber[800] : theme.colorScheme.primary,
        ),
        title: Text(
          update.isUnsupported ? 'Required Update' : 'New Update Available',
          textAlign: TextAlign.center,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Text(
                'Version ${update.versionName} (Build ${update.build})${sizeStr.isNotEmpty ? ' · $sizeStr' : ''}',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.hintColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (update.isUnsupported) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.amber.withValues(alpha: 0.4)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline, size: 20, color: Colors.amber),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This update is required to connect to messaging. Your calculator and encrypted local drafts are safe.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (update.releaseNotes.isNotEmpty) ...[
              Text(
                'What\'s New:',
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Container(
                constraints: const BoxConstraints(maxHeight: 140),
                child: SingleChildScrollView(
                  child: Text(
                    update.releaseNotes,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            const Text(
              'Downloads verified APK signed with official release keys.',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          if (!update.isUnsupported)
            TextButton(
              onPressed: () {
                onRemindLater?.call();
                Navigator.of(context).pop();
              },
              child: const Text('Remind me later'),
            ),
          FilledButton.icon(
            icon: const Icon(Icons.download, size: 18),
            label: const Text('Update Now'),
            onPressed: () async {
              final uri = Uri.parse(update.url);
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            },
          ),
        ],
      ),
    );
  }
}
