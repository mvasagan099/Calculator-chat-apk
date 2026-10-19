import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/security/vault_service.dart';
import '../../core/security/private_media_files.dart';
import 'package:local_auth/local_auth.dart';
import '../../core/widgets/actions.dart';
import '../../providers/app_providers.dart';
import '../media/document_viewer.dart';
import '../media/full_screen_image_viewer.dart';
import '../media/full_screen_video_viewer.dart';

enum VaultSortOrder {
  newest('Newest first'),
  oldest('Oldest first'),
  nameAsc('Name (A to Z)'),
  nameDesc('Name (Z to A)'),
  size('File size');

  const VaultSortOrder(this.label);
  final String label;
}

final vaultServiceProvider = Provider<VaultService>((ref) => VaultService());

class VaultScreen extends ConsumerStatefulWidget {
  const VaultScreen({super.key});

  @override
  ConsumerState<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends ConsumerState<VaultScreen> {
  late final VaultService _vault = ref.read(vaultServiceProvider);
  bool _authenticated = false;
  bool _loading = true;
  bool _needsBiometricPrompt = false;
  bool _isAuthenticating = false;
  String? _biometricStatus;
  String? _error;
  String _searchQuery = '';
  String _selectedFolder = 'All';
  VaultCategory? _selectedCategory;
  VaultStorageStats? _stats;
  VaultSortOrder _sortOrder = VaultSortOrder.newest;

  @override
  void initState() {
    super.initState();
    _checkAuthAndLoad();
  }

  Future<void> _checkAuthAndLoad() async {
    final device = ref.read(deviceSettingsProvider);
    if (device?.vaultBiometricsEnabled == true && !_authenticated) {
      setState(() {
        _loading = false;
        _needsBiometricPrompt = true;
        _error = null;
      });
      await _authenticateWithBiometrics();
    } else {
      _authenticated = true;
      await _loadVault();
    }
  }

  Future<void> _authenticateWithBiometrics() async {
    if (_isAuthenticating) return;
    _isAuthenticating = true;
    if (mounted) {
      setState(() {
        _isAuthenticating = true;
        _error = null;
      });
    }

    try {
      final auth = LocalAuthentication();
      final canCheck = await auth.canCheckBiometrics;
      final isSupported = await auth.isDeviceSupported();

      if (!canCheck && !isSupported) {
        if (mounted) {
          setState(() {
            _biometricStatus = 'Biometric authentication is not supported or enrolled on this device.';
            _isAuthenticating = false;
            _loading = false;
          });
        }
        return;
      }

      final lock = ref.read(lockProvider);
      final epoch = lock.securityEpoch;

      final ok = await auth.authenticate(
        localizedReason: 'Verify private vault access',
        biometricOnly: true,
        persistAcrossBackgrounding: false,
      );

      if (ok && lock.privateActionValid(epoch)) {
        if (mounted) {
          setState(() {
            _authenticated = true;
            _needsBiometricPrompt = false;
            _isAuthenticating = false;
          });
          await _loadVault();
        }
        return;
      } else {
        if (mounted) {
          setState(() {
            _biometricStatus = 'Authentication cancelled or unverified. Tap to retry.';
            _isAuthenticating = false;
            _loading = false;
          });
        }
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _biometricStatus = switch (e.code) {
            'LockedOut' => 'Too many attempts. Biometrics temporarily locked.',
            'PermanentlyLockedOut' => 'Biometrics permanently locked. Device unlock required.',
            'NotAvailable' => 'Biometric hardware unavailable.',
            'NotEnrolled' => 'No fingerprint or biometrics enrolled.',
            _ => 'Authentication failed: ${e.message ?? e.code}',
          };
          _isAuthenticating = false;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _biometricStatus = 'Authentication failed. Please retry.';
          _isAuthenticating = false;
          _loading = false;
        });
      }
    } finally {
      _isAuthenticating = false;
    }
  }

  Future<void> _loadVault() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      await _vault.initialize();
      final stats = await _vault.getStats();
      if (!mounted) return;
      if (!ref.read(lockProvider).unlocked) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _stats = stats;
        _authenticated = true;
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = 'Could not open the local encrypted vault. Your existing '
              'files were preserved. Check available device storage and retry.\n'
              'Details: $error';
          _loading = false;
        });
      }
    }
  }

  Future<void> _refresh() async {
    _stats = await _vault.getStats();
    if (mounted) setState(() {});
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Future<void> _importMedia(bool fromCamera) async {
    final picker = ImagePicker();
    final picked = fromCamera
        ? await picker.pickImage(source: ImageSource.camera)
        : await picker.pickMedia();
    if (picked == null || !mounted) return;

    await act(context, () async {
      final file = File(picked.path);
      await _vault.importFile(
        file: file,
        customName: picked.name,
        folder: _selectedFolder == 'All' ? 'Root' : _selectedFolder,
      );
      await _refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File securely imported into vault')),
        );
      }
    });
  }

  Future<void> _importDocument() async {
    final result = await FilePicker.pickFiles(type: FileType.any);
    if (result.isEmpty || result.first.path == null || !mounted) return;

    await act(context, () async {
      final file = File(result.first.path!);
      await _vault.importFile(
        file: file,
        customName: result.first.name,
        folder: _selectedFolder == 'All' ? 'Root' : _selectedFolder,
      );
      await _refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Document securely imported into vault')),
        );
      }
    });
  }

  Future<void> _viewItem(VaultItem item) async {
    await act(context, () async {
      final bytes = await _vault.readDecryptedBytes(item);
      try {
        if (!mounted) return;

      if (item.category == VaultCategory.images) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => FullScreenImageViewer(
              bytes: bytes,
              filename: item.filename,
              sizeBytes: item.sizeBytes,
            ),
          ),
        );
      } else if (item.category == VaultCategory.videos) {
        final privateFile = await PrivateMediaFiles().video(Uint8List.fromList(bytes));
        try {
          if (!mounted) return;
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => FullScreenVideoViewer(
                file: privateFile,
                filename: item.filename,
              ),
            ),
          );
        } finally {
          if (await privateFile.exists()) await privateFile.delete();
        }
      } else if (item.category == VaultCategory.audio) {
        await _playVaultAudio(item, bytes);
      } else {
        // Plain text or generic document viewer
        final ext = item.filename.split('.').last.toLowerCase();
        if (ext == 'txt') {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => TextDocumentViewer(
                filename: item.filename,
                content: String.fromCharCodes(bytes),
              ),
            ),
          );
        } else {
          // General document action
          await showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(item.filename),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Category: ${item.category.label}'),
                  Text('Size: ${_formatBytes(item.sizeBytes)}'),
                  Text('Folder: ${item.folder}'),
                  Text('Imported: ${DateFormat.yMMMd().format(item.createdAt)}'),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Close'),
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.share, size: 16),
                  label: const Text('Export...'),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await _exportItem(item, bytes);
                  },
                ),
              ],
            ),
          );
        }
      }
      } finally {
        bytes.fillRange(0, bytes.length, 0); // Minimize plaintext lifetime.
      }
    });
  }

  Future<void> _playVaultAudio(VaultItem item, Uint8List bytes) async {
    final tempDir = await getTemporaryDirectory();
    final ext = item.filename.contains('.')
        ? item.filename.split('.').last.toLowerCase()
        : 'm4a';
    final tempFile = File('${tempDir.path}/vault_audio_${item.id}.$ext');
    await tempFile.writeAsBytes(bytes, flush: true);

    try {
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => _VaultAudioPlayerSheet(
          filename: item.filename,
          audioFile: tempFile,
        ),
      );
    } finally {
      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _exportItem(VaultItem item, Uint8List bytes) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Export file from vault?'),
        content: const Text(
          'Exporting creates a temporary decrypted copy outside the private vault. Proceed only if intended.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Export'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    final base = await getTemporaryDirectory();
    final tempDir = await base.createTemp('vault-export-');
    // A legacy filename must not escape the app-private export directory.
    final sanitized = item.filename.replaceAll(RegExp(r'[\\/]'), '_');
    final safeName = sanitized.isEmpty || sanitized == '.' || sanitized == '..'
        ? 'vault-export.bin' : sanitized;
    final tempFile = File('${tempDir.path}/$safeName');
    try {
      await tempFile.writeAsBytes(bytes, flush: true);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(tempFile.path)], text: safeName),
      );
    } finally {
      // This clears only the app-owned temporary export, not the user's copy
      // explicitly saved into another app through the Android share sheet.
      try { await tempDir.delete(recursive: true); } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Private File Vault')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 48),
                const SizedBox(height: 16),
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _checkAuthAndLoad,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry opening vault'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (_needsBiometricPrompt && !_authenticated) {
      return Scaffold(
        appBar: AppBar(title: const Text('Private File Vault')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.fingerprint, size: 72, color: Colors.blueAccent),
                const SizedBox(height: 20),
                Text(
                  'Private Vault Locked',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(
                  _biometricStatus ?? 'Biometric verification is required to view your encrypted files.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).hintColor,
                  ),
                ),
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: _isAuthenticating ? null : _authenticateWithBiometrics,
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('Unlock with Fingerprint'),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (_loading || !_authenticated) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final filteredItems = _vault.filter(
      query: _searchQuery,
      folder: _selectedFolder,
      category: _selectedCategory,
    );

    switch (_sortOrder) {
      case VaultSortOrder.newest:
        filteredItems.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        break;
      case VaultSortOrder.oldest:
        filteredItems.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        break;
      case VaultSortOrder.nameAsc:
        filteredItems.sort((a, b) => a.filename.toLowerCase().compareTo(b.filename.toLowerCase()));
        break;
      case VaultSortOrder.nameDesc:
        filteredItems.sort((a, b) => b.filename.toLowerCase().compareTo(a.filename.toLowerCase()));
        break;
      case VaultSortOrder.size:
        filteredItems.sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
        break;
    }

    final folders = ['All', ..._vault.folders];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Private File Vault'),
        actions: [
          PopupMenuButton<VaultSortOrder>(
            tooltip: 'Sort files',
            icon: const Icon(Icons.sort),
            initialValue: _sortOrder,
            onSelected: (order) => setState(() => _sortOrder = order),
            itemBuilder: (ctx) => [
              for (final order in VaultSortOrder.values)
                PopupMenuItem(
                  value: order,
                  child: Row(
                    children: [
                      if (_sortOrder == order)
                        const Icon(Icons.check, size: 16)
                      else
                        const SizedBox(width: 16),
                      const SizedBox(width: 8),
                      Text(order.label),
                    ],
                  ),
                ),
            ],
          ),
          IconButton(
            tooltip: 'Vault storage info',
            icon: const Icon(Icons.pie_chart_outline),
            onPressed: () => _showStorageDialog(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showImportMenu,
        icon: const Icon(Icons.add_moderator),
        label: const Text('Import file'),
      ),
      body: Column(
        children: [
          // Search Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: SearchBar(
              hintText: 'Search vault files...',
              leading: const Icon(Icons.search),
              onChanged: (v) => setState(() => _searchQuery = v),
            ),
          ),
          // Storage Status Banner
          if (_stats != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${_stats!.fileCount} private files · ${_formatBytes(_stats!.vaultBytes)}',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                  const Text('Stored only on this device',
                      style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
          // Folder Filter Chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                for (final folder in folders)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: Text(folder),
                      selected: _selectedFolder == folder,
                      onSelected: (val) {
                        if (val) setState(() => _selectedFolder = folder);
                      },
                    ),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.create_new_folder_outlined, size: 16),
                  label: const Text('New folder'),
                  onPressed: _createFolderDialog,
                ),
              ],
            ),
          ),
          // Category Filter Chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FilterChip(
                    label: const Text('All types'),
                    selected: _selectedCategory == null,
                    onSelected: (val) {
                      if (val) setState(() => _selectedCategory = null);
                    },
                  ),
                ),
                for (final cat in VaultCategory.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: Text(cat.label),
                      selected: _selectedCategory == cat,
                      onSelected: (val) {
                        setState(() => _selectedCategory = val ? cat : null);
                      },
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 8),
          // Items List
          Expanded(
            child: filteredItems.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.shield_outlined,
                          size: 64,
                          color: Theme.of(context).hintColor.withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _searchQuery.isNotEmpty
                              ? 'No matching files found'
                              : 'No files in this vault folder',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Files are encrypted locally and never copied to gallery.',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.only(top: 4, bottom: 80),
                    itemCount: filteredItems.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final item = filteredItems[i];
                      return ListTile(
                        leading: CircleAvatar(
                          child: Icon(_categoryIcon(item.category)),
                        ),
                        title: Text(item.filename),
                        subtitle: Text(
                          '${item.folder} · ${_formatBytes(item.sizeBytes)} · ${DateFormat.yMMMd().format(item.createdAt)}',
                        ),
                        onTap: () => _viewItem(item),
                        trailing: PopupMenuButton<String>(
                          onSelected: (action) async {
                            if (action == 'rename') {
                              final name = await askText(
                                context,
                                'Rename file',
                                initial: item.filename,
                              );
                              if (name != null) {
                                await _vault.renameItem(item.id, name);
                                await _refresh();
                              }
                            } else if (action == 'move') {
                              _moveDialog(item);
                            } else if (action == 'delete') {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('Delete from vault?'),
                                  content: Text('Permanently remove "${item.filename}" from encrypted vault?'),
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
                              if (confirm == true) {
                                await _vault.deleteItem(item.id);
                                await _refresh();
                              }
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(value: 'rename', child: Text('Rename')),
                            const PopupMenuItem(value: 'move', child: Text('Move to folder')),
                            const PopupMenuItem(value: 'delete', child: Text('Delete file')),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  IconData _categoryIcon(VaultCategory cat) => switch (cat) {
    VaultCategory.images => Icons.image_outlined,
    VaultCategory.videos => Icons.videocam_outlined,
    VaultCategory.audio => Icons.audio_file_outlined,
    VaultCategory.documents => Icons.description_outlined,
    VaultCategory.other => Icons.insert_drive_file_outlined,
  };

  void _showImportMenu() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Import photo or video'),
              subtitle: const Text('Encrypt a local copy; original remains outside vault'),
              onTap: () {
                Navigator.pop(sheetContext);
                _importMedia(false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Take photo directly into vault'),
              subtitle: const Text('Encrypt photo into app-private vault storage'),
              onTap: () {
                Navigator.pop(sheetContext);
                _importMedia(true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.upload_file_outlined),
              title: const Text('Import document / audio / file'),
              subtitle: const Text('PDF, Word, Excel, Audio, ZIP, etc.'),
              onTap: () {
                Navigator.pop(sheetContext);
                _importDocument();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createFolderDialog() async {
    final folderName = await askText(context, 'New vault folder');
    if (!mounted) return;
    if (folderName != null && folderName.trim().isNotEmpty) {
      await act(context, () async {
        await _vault.addFolder(folderName.trim());
        if (mounted) setState(() => _selectedFolder = folderName.trim());
      });
    }
  }

  void _moveDialog(VaultItem item) {
    showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Move "${item.filename}" to:'),
        children: [
          for (final f in _vault.folders)
            SimpleDialogOption(
              onPressed: () async {
                Navigator.pop(ctx);
                await _vault.moveItem(item.id, f);
                await _refresh();
              },
              child: Text(f),
            ),
        ],
      ),
    );
  }

  void _showStorageDialog() {
    if (_stats == null) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Vault Storage Breakdown'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Total encrypted files: ${_stats!.fileCount}'),
            Text('Total vault size: ${_formatBytes(_stats!.vaultBytes)}'),
            const Divider(),
            for (final cat in VaultCategory.values)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(cat.label),
                    Text(_formatBytes(_stats!.categoryBytes[cat] ?? 0)),
                  ],
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class _VaultAudioPlayerSheet extends StatefulWidget {
  const _VaultAudioPlayerSheet({
    required this.filename,
    required this.audioFile,
  });

  final String filename;
  final File audioFile;

  @override
  State<_VaultAudioPlayerSheet> createState() => _VaultAudioPlayerSheetState();
}

class _VaultAudioPlayerSheetState extends State<_VaultAudioPlayerSheet> {
  late final AudioPlayer _player;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _speed = 1.0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _initAudio();
  }

  Future<void> _initAudio() async {
    try {
      final dur = await _player.setFilePath(widget.audioFile.path);
      if (dur != null) {
        _duration = dur;
      }
      _player.playerStateStream.listen((state) {
        if (!mounted) return;
        setState(() {
          _playing = state.playing && state.processingState != ProcessingState.completed;
          if (state.processingState == ProcessingState.completed) {
            _position = _duration;
          }
        });
      });
      _player.positionStream.listen((pos) {
        if (!mounted) return;
        setState(() => _position = pos);
      });
      _player.durationStream.listen((d) {
        if (!mounted || d == null) return;
        setState(() => _duration = d);
      });
      setState(() => _loading = false);
      await _player.play();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Failed to load audio: $e';
        });
      }
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        MediaQuery.of(context).padding.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Theme.of(context).dividerColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.audiotrack,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.filename,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Private Vault Audio',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).hintColor,
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: CircularProgressIndicator(),
            )
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            )
          else ...[
            Slider(
              value: _position.inMilliseconds
                  .clamp(0, _duration.inMilliseconds)
                  .toDouble(),
              max: (_duration.inMilliseconds > 0 ? _duration.inMilliseconds : 1)
                  .toDouble(),
              onChanged: (val) {
                _player.seek(Duration(milliseconds: val.round()));
              },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_formatDuration(_position), style: const TextStyle(fontSize: 12)),
                  Text(_formatDuration(_duration), style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton(
                  onPressed: () {
                    final nextSpeed = _speed == 1.0 ? 1.5 : (_speed == 1.5 ? 2.0 : 1.0);
                    setState(() => _speed = nextSpeed);
                    _player.setSpeed(nextSpeed);
                  },
                  child: Text(
                    '$_speed×',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton.filled(
                  iconSize: 40,
                  icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                  onPressed: () {
                    if (_playing) {
                      _player.pause();
                    } else {
                      if (_position >= _duration) {
                        _player.seek(Duration.zero);
                      }
                      _player.play();
                    }
                  },
                ),
                IconButton(
                  tooltip: 'Replay 10s',
                  icon: const Icon(Icons.replay_10),
                  onPressed: () {
                    final target = _position - const Duration(seconds: 10);
                    _player.seek(target < Duration.zero ? Duration.zero : target);
                  },
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

