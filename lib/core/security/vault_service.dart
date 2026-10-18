import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

enum VaultCategory {
  images,
  videos,
  audio,
  documents,
  other;

  String get label => switch (this) {
    VaultCategory.images => 'Images',
    VaultCategory.videos => 'Videos',
    VaultCategory.audio => 'Audio',
    VaultCategory.documents => 'Documents',
    VaultCategory.other => 'Other',
  };

  static VaultCategory fromExtension(String ext) {
    final clean = ext.toLowerCase().replaceAll('.', '');
    return switch (clean) {
      'jpg' || 'jpeg' || 'png' || 'webp' || 'gif' || 'bmp' => VaultCategory.images,
      'mp4' || 'mov' || 'avi' || 'mkv' || 'webm' => VaultCategory.videos,
      'mp3' || 'm4a' || 'ogg' || 'wav' || 'aac' || 'flac' => VaultCategory.audio,
      'pdf' || 'txt' || 'doc' || 'docx' || 'xls' || 'xlsx' || 'csv' => VaultCategory.documents,
      _ => VaultCategory.other,
    };
  }
}

class VaultItem {
  const VaultItem({
    required this.id,
    required this.filename,
    required this.folder,
    required this.category,
    required this.sizeBytes,
    required this.createdAt,
    required this.encryptedFilename,
    this.iv,
  });

  final String id;
  final String filename;
  final String folder;
  final VaultCategory category;
  final int sizeBytes;
  final DateTime createdAt;
  final String encryptedFilename;
  final String? iv;

  Map<String, dynamic> toJson() => {
    'id': id,
    'filename': filename,
    'folder': folder,
    'category': category.name,
    'size_bytes': sizeBytes,
    'created_at': createdAt.toIso8601String(),
    'encrypted_filename': encryptedFilename,
    if (iv != null) 'iv': iv,
  };

  factory VaultItem.fromJson(Map<String, dynamic> j) => VaultItem(
    id: j['id'] as String,
    filename: j['filename'] as String,
    folder: (j['folder'] as String?) ?? 'Root',
    category: VaultCategory.values.firstWhere(
      (c) => c.name == j['category'],
      orElse: () => VaultCategory.other,
    ),
    sizeBytes: (j['size_bytes'] as num?)?.toInt() ?? 0,
    createdAt: DateTime.tryParse(j['created_at'] as String? ?? '') ?? DateTime.now(),
    encryptedFilename: j['encrypted_filename'] as String,
    iv: j['iv'] as String?,
  );

  VaultItem copyWith({
    String? filename,
    String? folder,
    VaultCategory? category,
  }) => VaultItem(
    id: id,
    filename: filename ?? this.filename,
    folder: folder ?? this.folder,
    category: category ?? this.category,
    sizeBytes: sizeBytes,
    createdAt: createdAt,
    encryptedFilename: encryptedFilename,
    iv: iv,
  );
}

class VaultStorageStats {
  const VaultStorageStats({
    required this.vaultBytes,
    required this.fileCount,
    required this.categoryBytes,
    required this.freeDeviceBytes,
  });

  final int vaultBytes;
  final int fileCount;
  final Map<VaultCategory, int> categoryBytes;
  final int freeDeviceBytes;
}

/// Secure private file vault for images, videos, audio, and documents.
/// Encrypted with AES-GCM-256 and isolated in app-internal support directories.
/// Contents are NEVER copied to public Android gallery folders or uploaded to cloud.
class VaultService {
  VaultService({this.customDir, SecretKey? customKey}) : _customKey = customKey;

  final Directory? customDir;
  final SecretKey? _customKey;
  final AesGcm _aes = AesGcm.with256bits();

  static const _metaFile = 'vault_manifest.enc';
  static const _keyFile = 'vault_device.key';

  Directory? _vaultDirectory;
  SecretKey? _key;
  final List<VaultItem> _items = [];
  final Set<String> _folders = {'Root', 'Personal', 'Work', 'Financial'};
  bool _initialized = false;

  List<VaultItem> get items => List.unmodifiable(_items);
  List<String> get folders => List.unmodifiable(_folders.toList()..sort());

  Future<Directory> _getDir() async {
    if (_vaultDirectory != null) return _vaultDirectory!;
    if (customDir != null) {
      _vaultDirectory = customDir;
    } else {
      final base = await getApplicationSupportDirectory();
      _vaultDirectory = Directory('${base.path}/private-vault-v1');
    }
    await _vaultDirectory.create(recursive: true);
    return _vaultDirectory!;
  }

  /// Production keys are stored in Android-backed secure storage rather
  /// than alongside ciphertext. Custom directories are test fixtures only.
  Future<SecretKey> _getKey() async {
    if (_customKey != null) return _customKey!;
    if (_key != null) return _key!;
    final dir = await _getDir();
    final legacyFile = File('${dir.path}/$_keyFile');

    if (customDir != null) {
      // Isolated test fixtures do not depend on the Android Keystore plugin.
      if (await legacyFile.exists()) {
        final bytes = await legacyFile.readAsBytes();
        if (bytes.length != 32) throw StateError('Invalid test vault key');
        return _key = SecretKey(bytes);
      }
      final key = await _aes.newSecretKey();
      await legacyFile.writeAsBytes(await key.extractBytes(), flush: true);
      return _key = key;
    }

    const storageKey = 'calculator.private_vault_v1.aes_key';
    const storage = FlutterSecureStorage();
    String? encoded = await storage.read(key: storageKey);
    if (encoded != null) {
      final decoded = base64Decode(encoded);
      if (decoded.length != 32) throw StateError('Invalid protected vault key');
      if (await legacyFile.exists()) {
        // Never discard an older key if it differs from the protected copy.
        final legacy = await legacyFile.readAsBytes();
        if (base64Encode(legacy) != encoded) {
          throw StateError('Vault keys differ; preserve existing files');
        }
        await legacyFile.delete();
      }
      return _key = SecretKey(decoded);
    }

    if (await legacyFile.exists()) {
      final bytes = await legacyFile.readAsBytes();
      if (bytes.length != 32) throw StateError('Invalid legacy vault key');
      encoded = base64Encode(bytes);
      await storage.write(key: storageKey, value: encoded);
      if (await storage.read(key: storageKey) != encoded) {
        throw StateError('Unable to migrate vault key securely');
      }
      await legacyFile.delete();
      return _key = SecretKey(bytes);
    }
    if (await File('${dir.path}/$_metaFile').exists()) {
      throw StateError('Vault key missing; encrypted files preserved');
    }

    final generated = await _aes.newSecretKey();
    encoded = base64Encode(await generated.extractBytes());
    await storage.write(key: storageKey, value: encoded);
    if (await storage.read(key: storageKey) != encoded) {
      throw StateError('Unable to protect the new vault key');
    }
    return _key = generated;
  }

  Future<void> initialize() async {
    if (_initialized) return;
    final dir = await _getDir();
    final manifestFile = File('${dir.path}/$_metaFile');

    if (await manifestFile.exists()) {
      try {
        final encryptedBytes = await manifestFile.readAsBytes();
        if (encryptedBytes.length <= 28) {
          throw const FormatException('Invalid encrypted vault manifest');
        }
        {
          final nonce = encryptedBytes.sublist(0, 12);
          final mac = Mac(encryptedBytes.sublist(encryptedBytes.length - 16));
          final cipherText = encryptedBytes.sublist(12, encryptedBytes.length - 16);
          final key = await _getKey();
          final clearBytes = await _aes.decrypt(
            SecretBox(cipherText, nonce: nonce, mac: mac),
            secretKey: key,
          );
          final data = jsonDecode(utf8.decode(clearBytes)) as Map<String, dynamic>;
          final rawItems = (data['items'] as List? ?? []).cast<Map<String, dynamic>>();
          _items.clear();
          for (final j in rawItems) {
            _items.add(VaultItem.fromJson(j));
          }
          final rawFolders = (data['folders'] as List? ?? []).cast<String>();
          _folders.addAll(rawFolders);
        }
      } catch (_) {
        // Never reset metadata or overwrite existing ciphertext after a
        // decrypt/key/migration failure. Recovery must be explicit.
        throw StateError('Vault cannot be decrypted; preserve encrypted files');
      }
    }
    _initialized = true;
  }

  Future<void> _saveManifest() async {
    final dir = await _getDir();
    final manifestFile = File('${dir.path}/$_metaFile');
    final payload = jsonEncode({
      'items': _items.map((i) => i.toJson()).toList(),
      'folders': _folders.toList(),
    });
    final clearBytes = utf8.encode(payload);
    final key = await _getKey();
    final secretBox = await _aes.encrypt(clearBytes, secretKey: key);
    final fullPayload = Uint8List.fromList([
      ...secretBox.nonce,
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);
    await manifestFile.writeAsBytes(fullPayload, flush: true);
  }

  Future<VaultItem> importFile({
    required File file,
    String? customName,
    String folder = 'Root',
  }) async {
    await initialize();
    if (!await file.exists()) {
      throw const FileSystemException('Source file does not exist');
    }
    final rawBytes = await file.readAsBytes();
    if (rawBytes.isEmpty) {
      throw const FormatException('Cannot import empty file');
    }
    final originalName = customName ?? file.uri.pathSegments.last;
    return importBytes(
      bytes: rawBytes,
      filename: originalName,
      folder: folder,
    );
  }

  Future<VaultItem> importBytes({
    required Uint8List bytes,
    required String filename,
    String folder = 'Root',
  }) async {
    await initialize();
    final dir = await _getDir();
    final id = const Uuid().v4();
    final ext = filename.contains('.') ? filename.split('.').last : 'bin';
    final encName = '$id.enc';
    final targetFile = File('${dir.path}/$encName');

    final key = await _getKey();
    final secretBox = await _aes.encrypt(bytes, secretKey: key);
    final payload = Uint8List.fromList([
      ...secretBox.nonce,
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);
    await targetFile.writeAsBytes(payload, flush: true);

    final category = VaultCategory.fromExtension(ext);
    final item = VaultItem(
      id: id,
      filename: filename,
      folder: _folders.contains(folder) ? folder : 'Root',
      category: category,
      sizeBytes: bytes.length,
      createdAt: DateTime.now().toUtc(),
      encryptedFilename: encName,
    );

    _items.add(item);
    await _saveManifest();
    return item;
  }

  Future<Uint8List> readDecryptedBytes(VaultItem item) async {
    await initialize();
    final dir = await _getDir();
    final file = File('${dir.path}/${item.encryptedFilename}');
    if (!await file.exists()) {
      throw const FileSystemException('Encrypted vault item missing from storage');
    }
    final encryptedBytes = await file.readAsBytes();
    if (encryptedBytes.length < 28) {
      throw const FormatException('Corrupted vault item payload');
    }
    final nonce = encryptedBytes.sublist(0, 12);
    final mac = Mac(encryptedBytes.sublist(encryptedBytes.length - 16));
    final cipherText = encryptedBytes.sublist(12, encryptedBytes.length - 16);
    final key = await _getKey();
    final decrypted = await _aes.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: key,
    );
    return Uint8List.fromList(decrypted);
  }

  Future<void> renameItem(String id, String newName) async {
    await initialize();
    final index = _items.indexWhere((i) => i.id == id);
    if (index == -1) return;
    final clean = newName.trim();
    if (clean.isEmpty) return;
    _items[index] = _items[index].copyWith(filename: clean);
    await _saveManifest();
  }

  Future<void> moveItem(String id, String targetFolder) async {
    await initialize();
    final index = _items.indexWhere((i) => i.id == id);
    if (index == -1) return;
    addFolder(targetFolder);
    _items[index] = _items[index].copyWith(folder: targetFolder);
    await _saveManifest();
  }

  Future<void> deleteItem(String id) async {
    await initialize();
    final index = _items.indexWhere((i) => i.id == id);
    if (index == -1) return;
    final item = _items.removeAt(index);
    final dir = await _getDir();
    final file = File('${dir.path}/${item.encryptedFilename}');
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {}
    }
    await _saveManifest();
  }

  void addFolder(String folder) {
    final clean = folder.trim();
    if (clean.isNotEmpty) {
      _folders.add(clean);
    }
  }

  Future<void> removeFolder(String folder) async {
    if (folder == 'Root') return;
    _folders.remove(folder);
    for (var i = 0; i < _items.length; i++) {
      if (_items[i].folder == folder) {
        _items[i] = _items[i].copyWith(folder: 'Root');
      }
    }
    await _saveManifest();
  }

  List<VaultItem> filter({
    String? query,
    String? folder,
    VaultCategory? category,
  }) {
    return _items.where((i) {
      if (folder != null && folder != 'All' && i.folder != folder) return false;
      if (category != null && i.category != category) return false;
      if (query != null && query.trim().isNotEmpty) {
        final q = query.trim().toLowerCase();
        if (!i.filename.toLowerCase().contains(q)) return false;
      }
      return true;
    }).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<VaultStorageStats> getStats() async {
    await initialize();
    var totalBytes = 0;
    final catMap = <VaultCategory, int>{
      for (final cat in VaultCategory.values) cat: 0,
    };
    for (final item in _items) {
      totalBytes += item.sizeBytes;
      catMap[item.category] = (catMap[item.category] ?? 0) + item.sizeBytes;
    }
    return VaultStorageStats(
      vaultBytes: totalBytes,
      fileCount: _items.length,
      categoryBytes: catMap,
      freeDeviceBytes: 1024 * 1024 * 1024 * 10, // ~10 GB fallback
    );
  }

  Future<void> clearVault() async {
    final dir = await _getDir();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      await dir.create(recursive: true);
    }
    _items.clear();
    _folders.clear();
    _folders.addAll(['Root', 'Personal', 'Work', 'Financial']);
    _key = null;
    _initialized = false;
  }
}
