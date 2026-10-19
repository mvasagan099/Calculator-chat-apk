import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/security/encrypted_media_cache.dart';
import '../../core/security/media_cache_service.dart';
import '../../core/services/device_settings.dart';
import '../../core/widgets/actions.dart';
import '../../providers/app_providers.dart';
import '../vault/vault_screen.dart';

class StorageBreakdown {
  const StorageBreakdown({
    required this.cacheBytes,
    required this.imageBytes,
    required this.videoBytes,
    required this.audioBytes,
    required this.documentBytes,
    required this.mediaBytes,
    required this.databaseBytes,
    required this.vaultBytes,
    required this.totalBytes,
    required this.chatSizes,
    required this.largeFiles,
  });

  final int cacheBytes;
  final int imageBytes;
  final int videoBytes;
  final int audioBytes;
  final int documentBytes;
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
  String _statusMessage = 'Scanning storage…';
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
    setState(() {
      _loading = true;
      _statusMessage = 'Scanning storage breakdown…';
    });

    try {
      final tempDir = await getTemporaryDirectory();
      final appSupportDir = await getApplicationSupportDirectory();

      var cacheBytes = 0;
      var mediaBytes = 0;
      var databaseBytes = 0;
      var vaultBytes = 0;
      final largeFiles = <LargeFileItem>[];

      // 1. Scan temporary directory (isolated cache)
      if (await tempDir.exists()) {
        try {
          await for (final file in tempDir.list(recursive: true, followLinks: false)) {
            if (file is File) {
              try {
                final len = await file.length();
                cacheBytes += len;
                if (len > 2 * 1024 * 1024) {
                  largeFiles.add(LargeFileItem(
                    path: file.path,
                    filename: file.uri.pathSegments.last,
                    sizeBytes: len,
                    source: 'Temporary Cache',
                  ));
                }
              } catch (_) {}
            }
          }
        } catch (_) {}
      }

      // 2. Query MediaCacheService for exact media breakdown
      final owner = ref.read(supabaseProvider).auth.currentUser?.id;
      MediaStorageStats? mediaBreakdown;
      if (owner != null) {
        try {
          mediaBreakdown = await MediaCacheService().getStorageBreakdown(owner);
          mediaBytes = mediaBreakdown.totalBytes;
        } catch (_) {}
      }

      // 3. Scan private media directory for large files and fallback count
      final mediaDir = Directory('${appSupportDir.path}/private-media-v1');
      if (await mediaDir.exists()) {
        try {
          var scannedMediaBytes = 0;
          await for (final file in mediaDir.list(recursive: true, followLinks: false)) {
            if (file is File) {
              try {
                final len = await file.length();
                scannedMediaBytes += len;
                if (len > 2 * 1024 * 1024) {
                  largeFiles.add(LargeFileItem(
                    path: file.path,
                    filename: file.uri.pathSegments.last,
                    sizeBytes: len,
                    source: 'Chat Media',
                  ));
                }
              } catch (_) {}
            }
          }
          if (mediaBytes == 0) mediaBytes = scannedMediaBytes;
        } catch (_) {}
      }

      // 4. Scan database files (.db, .sqlite, .bin)
      try {
        await for (final file in appSupportDir.list(followLinks: false)) {
          if (file is File && (file.path.endsWith('.db') || file.path.endsWith('.bin') || file.path.endsWith('.sqlite'))) {
            try {
              databaseBytes += await file.length();
            } catch (_) {}
          }
        }
      } catch (_) {}

      // 5. Query Private Vault stats (safely, NEVER add vault files to bulk deletion largeFiles!)
      try {
        final vault = ref.read(vaultServiceProvider);
        await vault.initialize();
        final vaultStats = await vault.getStats();
        vaultBytes = vaultStats.vaultBytes;
      } catch (_) {}

      // 6. Per-chat storage estimates
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
            imageBytes: mediaBreakdown?.imageBytes ?? 0,
            videoBytes: mediaBreakdown?.videoBytes ?? 0,
            audioBytes: mediaBreakdown?.audioBytes ?? 0,
            documentBytes: mediaBreakdown?.documentBytes ?? 0,
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
        title: const Text('Clear temporary cache?'),
        content: const Text(
          'Remove temporary media and decrypted stream buffers from this device? Previously opened media will remain safe in the offline cache. Messages, drafts and Private Vault files will NOT be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear temporary cache'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    await act(context, () async {
      await MediaCacheService().clearTemporaryCache();
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

  Future<void> _clearDownloadedChatMedia() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear downloaded chat media?'),
        content: const Text(
          'Remove all downloaded chat photos, videos, voice messages and documents from device storage? Original chat messages will NOT be deleted, and attachments can be re-downloaded from Supabase when needed. Private Vault files are completely protected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear chat media'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    await act(context, () async {
      final owner = ref.read(supabaseProvider).auth.currentUser?.id;
      if (owner != null) {
        await MediaCacheService().clearDownloadedChatMedia(owner);
        await EncryptedMediaCache().clear(owner);
      }
      await _loadStorage();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Downloaded chat media cleared')),
        );
      }
    });
  }

  Future<void> _clearConversationCacheDialog() async {
    final conversations = _stats?.chatSizes ?? [];
    if (conversations.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No active conversations found')),
      );
      return;
    }

    final chosen = await showDialog<ChatStorageItem>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Select conversation to clear'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: conversations.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (c, i) {
              final chat = conversations[i];
              return ListTile(
                title: Text(chat.title),
                trailing: const Icon(Icons.arrow_forward_ios, size: 14),
                onTap: () => Navigator.pop(ctx, chat),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Clear media for "${chosen.title}"?'),
        content: const Text(
          'All cached attachments for this conversation will be removed from device storage. Messages remain untouched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    await act(context, () async {
      final owner = ref.read(supabaseProvider).auth.currentUser?.id;
      if (owner != null) {
        await MediaCacheService().clearConversationCache(owner, chosen.conversationId);
      }
      await _loadStorage();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Media cleared for ${chosen.title}')),
        );
      }
    });
  }

  Future<void> _clearThumbnails() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear cached thumbnails?'),
        content: const Text(
          'Remove cached media thumbnails? Full attachments remain untouched, and thumbnails will regenerate as you scroll through messages.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear thumbnails'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    await act(context, () async {
      final owner = ref.read(supabaseProvider).auth.currentUser?.id;
      if (owner != null) {
        await MediaCacheService().clearThumbnails(owner);
      }
      await _loadStorage();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Thumbnails cache cleared')),
        );
      }
    });
  }

  Future<void> _runAutoCleanup() async {
    await act(context, () async {
      final owner = ref.read(supabaseProvider).auth.currentUser?.id;
      if (owner != null) {
        await MediaCacheService().prune(owner);
      }
      await _loadStorage();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Automatic LRU cache cleanup completed')),
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
    final settings = ref.watch(deviceSettingsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Storage & Data'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loadStorage,
          ),
        ],
      ),
      body: _loading
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  if (_statusMessage.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                      _statusMessage,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ],
              ),
            )
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
                                  flex: _stats!.imageBytes + 1,
                                  color: Colors.blue,
                                ),
                                _ProgressBarSegment(
                                  flex: _stats!.videoBytes + 1,
                                  color: Colors.orange,
                                ),
                                _ProgressBarSegment(
                                  flex: _stats!.audioBytes + 1,
                                  color: Colors.teal,
                                ),
                                _ProgressBarSegment(
                                  flex: _stats!.documentBytes + 1,
                                  color: Colors.indigo,
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
                            _LegendIndicator(color: Colors.blue, label: 'Photos: ${_formatBytes(_stats!.imageBytes)}'),
                            _LegendIndicator(color: Colors.orange, label: 'Videos: ${_formatBytes(_stats!.videoBytes)}'),
                            _LegendIndicator(color: Colors.teal, label: 'Audio: ${_formatBytes(_stats!.audioBytes)}'),
                            _LegendIndicator(color: Colors.indigo, label: 'Docs: ${_formatBytes(_stats!.documentBytes)}'),
                            _LegendIndicator(color: Colors.purple, label: 'Private Vault: ${_formatBytes(_stats!.vaultBytes)}'),
                            _LegendIndicator(color: Colors.green, label: 'Chats DB: ${_formatBytes(_stats!.databaseBytes)}'),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Max Cache Size Section
                Text(
                  'Maximum Cache Size',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  'Automatically removes least recently used chat media when exceeded. Private Vault data is never deleted.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
                ),
                const SizedBox(height: 8),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.2)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<CacheSizeLimit>(
                        isExpanded: true,
                        value: settings?.cacheSizeLimit ?? CacheSizeLimit.gb2,
                        items: CacheSizeLimit.values.map((limit) {
                          return DropdownMenuItem<CacheSizeLimit>(
                            value: limit,
                            child: Text(limit.label),
                          );
                        }).toList(),
                        onChanged: (newLimit) {
                          if (newLimit != null) {
                            settings?.setCacheSizeLimit(newLimit);
                            MediaCacheService.globalMaxCacheBytes = newLimit.bytes;
                            setState(() {});
                          }
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Automatic Media Downloads Section
                Text(
                  'Automatic Media Download',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  'Configure network policy for offline background caching.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
                ),
                const SizedBox(height: 8),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.2)),
                  ),
                  child: Column(
                    children: [
                      _AutoDownloadTile(
                        icon: Icons.photo_outlined,
                        title: 'Photos',
                        current: settings?.autoDownloadPhotos ?? AutoDownloadPolicy.wifiOnly,
                        onChanged: (p) {
                          if (p != null) {
                            settings?.setAutoDownloadPhotos(p);
                            setState(() {});
                          }
                        },
                      ),
                      const Divider(height: 1),
                      _AutoDownloadTile(
                        icon: Icons.videocam_outlined,
                        title: 'Videos',
                        current: settings?.autoDownloadVideos ?? AutoDownloadPolicy.manual,
                        onChanged: (p) {
                          if (p != null) {
                            settings?.setAutoDownloadVideos(p);
                            setState(() {});
                          }
                        },
                      ),
                      const Divider(height: 1),
                      _AutoDownloadTile(
                        icon: Icons.mic_none_outlined,
                        title: 'Voice messages',
                        current: settings?.autoDownloadVoice ?? AutoDownloadPolicy.wifiAndCellular,
                        onChanged: (p) {
                          if (p != null) {
                            settings?.setAutoDownloadVoice(p);
                            setState(() {});
                          }
                        },
                      ),
                      const Divider(height: 1),
                      _AutoDownloadTile(
                        icon: Icons.description_outlined,
                        title: 'Documents',
                        current: settings?.autoDownloadDocuments ?? AutoDownloadPolicy.manual,
                        onChanged: (p) {
                          if (p != null) {
                            settings?.setAutoDownloadDocuments(p);
                            setState(() {});
                          }
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Cache Cleanup Actions Section
                Text(
                  'Cache Maintenance',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.2)),
                  ),
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.cleaning_services_outlined),
                        title: const Text('Clear Temporary Cache'),
                        subtitle: const Text('Free temporary decrypted stream buffers'),
                        trailing: TextButton(
                          onPressed: _clearTempCache,
                          child: const Text('Clear'),
                        ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.folder_delete_outlined),
                        title: const Text('Clear Downloaded Chat Media'),
                        subtitle: Text('Frees ${_formatBytes(_stats!.cacheBytes)} across all chats'),
                        trailing: TextButton(
                          onPressed: _stats!.cacheBytes > 0 ? _clearDownloadedChatMedia : null,
                          child: const Text('Clear'),
                        ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.chat_bubble_outline),
                        title: const Text('Clear Selected Conversation Media'),
                        subtitle: const Text('Choose a specific chat to free up cached media'),
                        trailing: TextButton(
                          onPressed: _clearConversationCacheDialog,
                          child: const Text('Select'),
                        ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.photo_size_select_actual_outlined),
                        title: const Text('Clear Cached Thumbnails'),
                        subtitle: const Text('Reclaims thumbnail storage; regenerates as you scroll'),
                        trailing: TextButton(
                          onPressed: _clearThumbnails,
                          child: const Text('Clear'),
                        ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.auto_mode_outlined),
                        title: const Text('Run Auto-Cleanup Now'),
                        subtitle: const Text('Applies least-recently-used cache eviction immediately'),
                        trailing: TextButton(
                          onPressed: _runAutoCleanup,
                          child: const Text('Run'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

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
                          'Local cache cleanup frees device storage. It does NOT delete cloud messages or uncommitted offline drafts. Private Vault files are protected and never deleted by automatic cleanup.',
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

class _AutoDownloadTile extends StatelessWidget {
  const _AutoDownloadTile({
    required this.icon,
    required this.title,
    required this.current,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final AutoDownloadPolicy current;
  final ValueChanged<AutoDownloadPolicy?> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: DropdownButtonHideUnderline(
        child: DropdownButton<AutoDownloadPolicy>(
          value: current,
          items: AutoDownloadPolicy.values.map((policy) {
            return DropdownMenuItem(
              value: policy,
              child: Text(policy.label),
            );
          }).toList(),
          onChanged: onChanged,
        ),
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
