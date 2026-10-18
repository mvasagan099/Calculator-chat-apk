import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/security/vault_service.dart';
import '../../core/widgets/actions.dart';
import '../../providers/app_providers.dart';
import '../vault/vault_screen.dart';

class StorageBreakdown {
  const StorageBreakdown({
    required this.cacheBytes,
    required this.mediaBytes,
    required this.databaseBytes,
    required this.vaultBytes,
    required this.totalBytes,
    required this.chatSizes,
    required this.largeFiles,
  });

  final int cacheBytes;
  final int mediaBytes;
  final int databaseBytes;
  final int vaultBytes;
  final int totalBytes;
  final List<ChatStorageItem> chatSizes;
  final List<LargeFileItem> largeFiles;
}

class ChatStorageItem {
  const ChatStorageItem({
    required this.conversationId,
    required this.title,
    required this.messageCount,
    required this.mediaBytes,
  });

  final String conversationId;
  final String title;
  final int messageCount;
  final int mediaBytes;
}

class LargeFileItem {
  const LargeFileItem({
    required this.path,
    required this.filename,
    required this.sizeBytes,
    required this.source,
  });

  final String path;
  final String filename;
  final int sizeBytes;
  final String source;
}

class StorageManagerScreen extends ConsumerStatefulWidget {
  const StorageManagerScreen({super.key});

  @override
  ConsumerState<StorageManagerScreen> createState() => _StorageManagerScreenState();
}

class _StorageManagerScreenState extends ConsumerState<StorageManagerScreen> {
  bool _loading = true;
  StorageBreakdown? _stats;
  final Set<String> _selectedLargeFiles = {};

  @override
  void initState() {
    super.initState();
    _loadStorage();
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Future<void> _loadStorage() async {
    setState(() => _loading = true);

    try {
      final tempDir = await getTemporaryDirectory();
      final appSupportDir = await getApplicationSupportDirectory();

      var cacheBytes = 0;
      var mediaBytes = 0;
      var databaseBytes = 0;
      final largeFiles = <LargeFileItem>[];

      // 1. Scan temp directory (cache)
      if (await tempDir.exists()) {
        await for (final file in tempDir.list(recursive: true, followLinks: false)) {
          if (file is File) {
            final len = await file.length();
            cacheBytes += len;
            if (len > 2 * 1024 * 1024) {
              largeFiles.add(LargeFileItem(
                path: file.path,
                filename: file.uri.pathSegments.last,
                sizeBytes: len,
                source: 'Cache',
              ));
            }
          }
        }
      }

      // 2. Scan private media directory
      final mediaDir = Directory('${appSupportDir.path}/private-media-v1');
      if (await mediaDir.exists()) {
        await for (final file in mediaDir.list(recursive: true, followLinks: false)) {
          if (file is File) {
            final len = await file.length();
            mediaBytes += len;
            if (len > 2 * 1024 * 1024) {
              largeFiles.add(LargeFileItem(
                path: file.path,
                filename: file.uri.pathSegments.last,
                sizeBytes: len,
                source: 'Media',
              ));
            }
          }
        }
      }

      // 3. Scan sqlite database files
      await for (final file in appSupportDir.list(followLinks: false)) {
        if (file is File && (file.path.endsWith('.db') || file.path.endsWith('.bin'))) {
          final len = await file.length();
          databaseBytes += len;
        }
      }

      // 4. Scan vault files
      final vault = ref.read(vaultServiceProvider);
      await vault.initialize();
      final vaultStats = await vault.getStats();
      final vaultBytes = vaultStats.vaultBytes;

      for (final item in vault.items) {
        if (item.sizeBytes > 2 * 1024 * 1024) {
          largeFiles.add(LargeFileItem(
            path: item.id,
            filename: item.filename,
            sizeBytes: item.sizeBytes,
            source: 'Vault (${item.folder})',
          ));
        }
      }

      // 5. Per-chat storage estimates
      final chatSizes = <ChatStorageItem>[];
      try {
        final convList = await ref.read(messengerProvider).conversations().first;
        for (final c in convList) {
          chatSizes.add(ChatStorageItem(
            conversationId: c['id'] as String,
            title: c['title'] as String? ?? 'Chat',
            messageCount: c['unread'] as int? ?? 0,
            mediaBytes: 0,
          ));
        }
      } catch (_) {}

      final totalBytes = cacheBytes + mediaBytes + databaseBytes + vaultBytes;

      if (mounted) {
        setState(() {
          _stats = StorageBreakdown(
            cacheBytes: cacheBytes,
            mediaBytes: mediaBytes,
            databaseBytes: databaseBytes,
            vaultBytes: vaultBytes,
            totalBytes: totalBytes,
            chatSizes: chatSizes,
            largeFiles: largeFiles..sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes)),
          );
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _clearTempCache() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear temporary media cache?'),
        content: const Text(
          'This removes locally cached preview thumbnails and temporary streaming files. Messages, unsent drafts, and private vault files will NOT be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear cache'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    await act(context, () async {
      final tempDir = await getTemporaryDirectory();
      if (await tempDir.exists()) {
        await for (final child in tempDir.list(followLinks: false)) {
          try {
            await child.delete(recursive: true);
          } catch (_) {}
        }
      }
      await _loadStorage();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Temporary cache cleared')),
        );
      }
    });
  }

  Future<void> _deleteSelectedLargeFiles() async {
    if (_selectedLargeFiles.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${_selectedLargeFiles.length} selected files?'),
        content: const Text(
          'Selected local files will be removed from device storage.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    await act(context, () async {
      for (final path in _selectedLargeFiles) {
        final f = File(path);
        if (await f.exists()) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
      _selectedLargeFiles.clear();
      await _loadStorage();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Selected files cleaned up')),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Storage Manager'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loadStorage,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _stats == null
          ? const Center(child: Text('Failed to calculate storage.'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Storage Summary Header
                Card(
                  elevation: 0,
                  color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Total App Storage',
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: Theme.of(context).hintColor,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _formatBytes(_stats!.totalBytes),
                          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 16),
                        // Storage progress bar
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            height: 10,
                            child: Row(
                              children: [
                                _ProgressBarSegment(
                                  flex: _stats!.mediaBytes + 1,
                                  color: Colors.blue,
                                ),
                                _ProgressBarSegment(
                                  flex: _stats!.cacheBytes + 1,
                                  color: Colors.amber,
                                ),
                                _ProgressBarSegment(
                                  flex: _stats!.vaultBytes + 1,
                                  color: Colors.purple,
                                ),
                                _ProgressBarSegment(
                                  flex: _stats!.databaseBytes + 1,
                                  color: Colors.green,
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        // Legend
                        Wrap(
                          spacing: 16,
                          runSpacing: 8,
                          children: [
                            _LegendIndicator(color: Colors.blue, label: 'Media: ${_formatBytes(_stats!.mediaBytes)}'),
                            _LegendIndicator(color: Colors.amber, label: 'Cache: ${_formatBytes(_stats!.cacheBytes)}'),
                            _LegendIndicator(color: Colors.purple, label: 'Vault: ${_formatBytes(_stats!.vaultBytes)}'),
                            _LegendIndicator(color: Colors.green, label: 'Chats DB: ${_formatBytes(_stats!.databaseBytes)}'),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Quick Cleanup Actions
                ListTile(
                  leading: const Icon(Icons.cleaning_services_outlined),
                  title: const Text('Clear Temporary Cache'),
                  subtitle: Text('Free up ${_formatBytes(_stats!.cacheBytes)} of reusable temp data'),
                  trailing: TextButton(
                    onPressed: _stats!.cacheBytes > 0 ? _clearTempCache : null,
                    child: const Text('Clean'),
                  ),
                ),
                const Divider(),

                // Large Files Section
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Large Files (${_stats!.largeFiles.length})',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (_selectedLargeFiles.isNotEmpty)
                      FilledButton.tonalIcon(
                        icon: const Icon(Icons.delete_outline, size: 16),
                        label: Text('Delete (${_selectedLargeFiles.length})'),
                        onPressed: _deleteSelectedLargeFiles,
                      ),
                  ],
                ),
                const SizedBox(height: 8),

                if (_stats!.largeFiles.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: Text('No files over 2 MB found on device.'),
                    ),
                  )
                else
                  for (final file in _stats!.largeFiles.take(15))
                    CheckboxListTile(
                      value: _selectedLargeFiles.contains(file.path),
                      onChanged: (val) {
                        setState(() {
                          if (val == true) {
                            _selectedLargeFiles.add(file.path);
                          } else {
                            _selectedLargeFiles.remove(file.path);
                          }
                        });
                      },
                      title: Text(
                        file.filename,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('${file.source} · ${_formatBytes(file.sizeBytes)}'),
                    ),

                const Divider(),
                // Privacy Protection Notice
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.shield_outlined,
                        size: 20,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Local cache cleanup frees device storage. It does NOT delete cloud messages or uncommitted offline drafts. Private vault files are protected.',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _ProgressBarSegment extends StatelessWidget {
  const _ProgressBarSegment({required this.flex, required this.color});
  final int flex;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex.clamp(1, 1000000000),
      child: Container(color: color),
    );
  }
}

class _LegendIndicator extends StatelessWidget {
  const _LegendIndicator({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
