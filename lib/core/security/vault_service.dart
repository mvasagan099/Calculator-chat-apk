// ignore_for_file: prefer_initializing_formals
// Keep the public customKey test fixture while storing keys securely in production.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:sqflite/sqflite.dart';

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
    this.contentHash,
  });

  final String id;
  final String filename;
  final String folder;
  final VaultCategory category;
  final int sizeBytes;
  final DateTime createdAt;
  final String encryptedFilename;
  final String? iv;
  final String? contentHash;

  Map<String, dynamic> toJson() => {
    'id': id,
    'filename': filename,
    'folder': folder,
    'category': category.name,
    'size_bytes': sizeBytes,
    'created_at': createdAt.toIso8601String(),
    'encrypted_filename': encryptedFilename,
    if (iv != null) 'iv': iv,
    if (contentHash != null) 'content_hash': contentHash,
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
    contentHash: j['content_hash'] as String?,
  );

  VaultItem copyWith({
    String? filename,
    String? folder,
    VaultCategory? category,
    String? contentHash,
  }) => VaultItem(
    id: id,
    filename: filename ?? this.filename,
    folder: folder ?? this.folder,
    category: category ?? this.category,
    sizeBytes: sizeBytes,
    createdAt: createdAt,
    encryptedFilename: encryptedFilename,
    iv: iv,
    contentHash: contentHash ?? this.contentHash,
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
  VaultService({this.customDir, SecretKey? customKey, DatabaseFactory? factory})
      : _customKey = customKey,
        _factory = factory ?? databaseFactory;

  final Directory? customDir;
  final SecretKey? _customKey;
  final DatabaseFactory _factory;
  final AesGcm _aes = AesGcm.with256bits();

  // v1 encrypted manifest is retained until a verified SQLite migration.
  static const _metaFile = 'vault_manifest.enc';
  static const _keyFile = 'vault_device.key';
  static const _indexFile = 'vault_index.sqlite';
  static const _indexAad = 'calculator-private-vault:index:v1';

  Directory? _vaultDirectory;
  SecretKey? _key;
  Database? _db;
  Future<void>? _initializing;
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
    final directory = _vaultDirectory!;
    await directory.create(recursive: true);
    return directory;
  }

  /// Production keys are stored in Android-backed secure storage rather
  /// than alongside ciphertext. Custom directories are test fixtures only.
  Future<SecretKey> _getKey() async {
    if (_customKey case final key?) return key;
    if (_key != null) return _key!;
    final dir = await _getDir();
    final legacyFile = File('${dir.path}/$_keyFile');

    if (customDir != null) {
      // Host test fixture, never used in production.
      if (await legacyFile.exists()) {
        final bytes = await legacyFile.readAsBytes();
        if (bytes.length != 32) throw StateError('Invalid test vault key');
        return _key = SecretKey(bytes);
      }
      if (await File('${dir.path}/$_indexFile').exists() ||
          await File('${dir.path}/$_metaFile').exists() ||
          (await dir.list(followLinks: false).toList()).whereType<File>()
              .any((file) => file.path.endsWith('.enc'))) {
        throw StateError('Missing local vault test key; encrypted files preserved');
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
    if (await File('${dir.path}/$_metaFile').exists() ||
        await File('${dir.path}/$_indexFile').exists() ||
        (await dir.list(followLinks: false).toList())
            .whereType<File>().any((file) => file.path.endsWith('.enc'))) {
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

  /// The SQLite file contains only authenticated ciphertext. Filenames,
  /// folder names and categories cannot be read from the raw database.
  /// The encrypted original file blobs stay in the existing app-private folder.
  Future<void> initialize() {
    if (_initialized) return Future<void>.value();
    return _initializing ??= _initializeIndex().whenComplete(() {
      _initializing = null;
    });
  }

  Future<void> _initializeIndex() async {
    final dir = await _getDir();
    final legacy = File('${dir.path}/$_metaFile');
    try {
      // Read the existing key before touching metadata. Never generate a new
      // key over an existing encrypted vault.
      await _getKey();
      final db = await _factory.openDatabase(
        '${dir.path}/$_indexFile',
        options: OpenDatabaseOptions(
          version: 1,
          singleInstance: false,
          onConfigure: (database) async {
            // journal_mode is configured by sqflite on Android; changing it
            // from inside onConfigure can fail while the open transaction is
            // active, preventing an otherwise healthy local vault from opening.
            await database.execute('PRAGMA secure_delete=ON');
          },
          onCreate: (database, _) async {
            await database.execute(
              'CREATE TABLE vault_state (id INTEGER PRIMARY KEY CHECK(id = 1), '
              'nonce BLOB NOT NULL, payload BLOB NOT NULL, tag BLOB NOT NULL)',
            );
          },
        ),
      );
      _db = db;
      final rows = await db.query('vault_state', where: 'id = ?', whereArgs: [1]);
      if (rows.isNotEmpty) {
        _decodeState(await _decryptState(rows.single));
      } else if (await legacy.exists()) {
        // Upgrade the existing AES-GCM manifest transactionally; keep all
        // encrypted file blobs in their original location and format.
        final bytes = await legacy.readAsBytes();
        if (bytes.length <= 28) throw const FormatException('Invalid legacy vault manifest');
        _decodeState(await _decryptPayload(bytes));
        await _saveManifest();
        final migrated = await db.query('vault_state', where: 'id = ?', whereArgs: [1]);
        if (migrated.length != 1 ||
            jsonEncode(await _decryptState(migrated.single)) != jsonEncode(_stateData())) {
          throw StateError('Vault migration verification failed');
        }
        // Delete only after the new encrypted SQLite state is verified.
        await legacy.delete();
      } else {
        // Recover any existing orphaned encrypted files instead of throwing fatal errors.
        final children = await dir.list(followLinks: false).toList();
        final encFiles = children.whereType<File>().where((file) => file.path.endsWith('.enc')).toList();
        if (encFiles.isNotEmpty) {
          final key = await _getKey();
          for (final file in encFiles) {
            final encName = file.uri.pathSegments.last;
            final id = encName.replaceFirst(RegExp(r'\.enc$'), '');
            try {
              final raw = await file.readAsBytes();
              if (raw.length >= 28) {
                final nonce = raw.sublist(0, 12);
                final mac = Mac(raw.sublist(raw.length - 16));
                final cipherText = raw.sublist(12, raw.length - 16);
                final plain = await _aes.decrypt(
                  SecretBox(cipherText, nonce: nonce, mac: mac),
                  secretKey: key,
                );
                final ext = _detectExtension(plain);
                final hash = (await Sha256().hash(plain)).bytes
                    .map((b) => b.toRadixString(16).padLeft(2, '0')).join();
                _items.add(VaultItem(
                  id: id,
                  filename: 'recovered_$id.$ext',
                  folder: 'Root',
                  category: VaultCategory.fromExtension(ext),
                  sizeBytes: plain.length,
                  createdAt: await file.lastModified(),
                  encryptedFilename: encName,
                  contentHash: hash,
                ));
              }
            } catch (_) {}
          }
        }
        await _saveManifest();
      }
      _initialized = true;
    } catch (error) {
      try { await _db?.close(); } catch (_) {}
      _db = null;
      _initialized = false;
      _items.clear();
      _folders..clear()..addAll({'Root', 'Personal', 'Work', 'Financial'});
      throw StateError(
        'Private vault could not open locally. Existing encrypted files are '
        'preserved; do not clear app data. Cause: ${error.runtimeType}',
      );
    }
  }

  Map<String, dynamic> _stateData() => {
    'items': _items.map((item) => item.toJson()).toList(),
    'folders': _folders.toList(),
  };

  void _decodeState(Map<String, dynamic> data) {
    final rawItems = data['items'];
    final rawFolders = data['folders'];
    if (rawItems is! List || rawFolders is! List) {
      throw const FormatException('Invalid vault index');
    }
    final imported = <VaultItem>[];
    final ids = <String>{};
    for (final value in rawItems) {
      if (value is! Map<String, dynamic>) throw const FormatException('Invalid vault entry');
      final item = VaultItem.fromJson(value);
      if (!ids.add(item.id) ||
          !RegExp(r'^[0-9a-fA-F-]{36}\.enc$').hasMatch(item.encryptedFilename)) {
        throw const FormatException('Invalid encrypted vault item');
      }
      imported.add(item);
    }
    final folders = rawFolders.cast<String>().toSet()..add('Root');
    _items..clear()..addAll(imported);
    _folders..clear()..addAll(folders);
  }

  Future<Map<String, dynamic>> _decryptPayload(List<int> bytes) async {
    if (bytes.length <= 28) throw const FormatException('Invalid encrypted vault payload');
    final plain = await _aes.decrypt(
      SecretBox(
        bytes.sublist(12, bytes.length - 16),
        nonce: bytes.sublist(0, 12),
        mac: Mac(bytes.sublist(bytes.length - 16)),
      ),
      secretKey: await _getKey(),
    );
    return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _decryptState(Map<String, Object?> row) async {
    final clear = await _aes.decrypt(
      SecretBox(
        row['payload'] as Uint8List,
        nonce: row['nonce'] as Uint8List,
        mac: Mac(row['tag'] as Uint8List),
      ),
      secretKey: await _getKey(),
      aad: utf8.encode(_indexAad),
    );
    return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
  }

  Future<void> _saveManifest() async {
    final db = _db;
    if (db == null) throw StateError('Private vault SQLite is not open');
    final box = await _aes.encrypt(
      utf8.encode(jsonEncode(_stateData())),
      secretKey: await _getKey(),
      aad: utf8.encode(_indexAad),
    );
    await db.transaction((txn) async {
      await txn.insert('vault_state', {
        'id': 1,
        'nonce': Uint8List.fromList(box.nonce),
        'payload': Uint8List.fromList(box.cipherText),
        'tag': Uint8List.fromList(box.mac.bytes),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<void> close() async {
    await _initializing;
    await _db?.close();
    _db = null;
    _key = null;
    _initialized = false;
    _items.clear();
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
    final length = await file.length();
    if (length == 0) throw const FormatException('Cannot import empty file');
    if (length > 100 * 1024 * 1024) {
      throw const FormatException('Vault imports must be 100 MB or smaller');
    }
    final rawBytes = await file.readAsBytes();
    try {
      return await importBytes(
        bytes: rawBytes,
        filename: customName ?? file.uri.pathSegments.last,
        folder: folder,
      );
    } finally {
      rawBytes.fillRange(0, rawBytes.length, 0);
    }
  }

  static String _detectExtension(List<int> bytes) {
    if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return 'jpg';
    }
    if (bytes.length >= 4 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
      return 'png';
    }
    if (bytes.length >= 3 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
      return 'gif';
    }
    if (bytes.length >= 12 && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
        bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50) {
      return 'webp';
    }
    if (bytes.length >= 4 && bytes[0] == 0x25 && bytes[1] == 0x50 && bytes[2] == 0x44 && bytes[3] == 0x46) {
      return 'pdf';
    }
    if (bytes.length >= 8 && bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70) {
      return 'mp4';
    }
    if (bytes.length >= 3 && ((bytes[0] == 0x49 && bytes[1] == 0x43 && bytes[2] == 0x33) ||
        (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0))) {
      return 'mp3';
    }
    if (bytes.length >= 4 && bytes[0] == 0x4F && bytes[1] == 0x67 && bytes[2] == 0x67 && bytes[3] == 0x53) {
      return 'ogg';
    }
    return 'bin';
  }

  VaultItem? findByHash(String hash) =>
      _items.where((item) => item.contentHash == hash).firstOrNull;

  Future<VaultItem> importBytes({
    required Uint8List bytes,
    required String filename,
    String folder = 'Root',
  }) async {
    await initialize();
    if (bytes.isEmpty) throw const FormatException('Cannot import empty file');
    if (bytes.length > 100 * 1024 * 1024) {
      throw const FormatException('Vault imports must be 100 MB or smaller');
    }
    final cleanName = filename.replaceAll(RegExp(r'[\\/]'), '_').trim();
    if (cleanName.isEmpty || cleanName == '.' || cleanName == '..') {
      throw const FormatException('Invalid vault filename');
    }

    final hashDigest = await Sha256().hash(bytes);
    final contentHash = hashDigest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    // Avoid unnecessary duplicate storage if exact same file is already in vault
    final existing = findByHash(contentHash);
    if (existing != null) {
      return existing;
    }

    final dir = await _getDir();
    final id = const Uuid().v4();
    final ext = cleanName.contains('.') ? cleanName.split('.').last : 'bin';
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
      filename: cleanName,
      folder: _folders.contains(folder) ? folder : 'Root',
      category: category,
      sizeBytes: bytes.length,
      createdAt: DateTime.now().toUtc(),
      encryptedFilename: encName,
      contentHash: contentHash,
    );

    _items.add(item);
    try { await _saveManifest(); } catch (_) {
      _items.removeWhere((entry) => entry.id == item.id);
      // Preserve ciphertext for recovery if the index write fails.
      rethrow;
    }
    return item;
  }

  /// Copies a chat attachment into the Private Vault as an independent, protected file.
  Future<VaultItem> importChatAttachment({
    required Uint8List bytes,
    required String filename,
    String folder = 'Root',
  }) async {
    return await importBytes(
      bytes: bytes,
      filename: filename,
      folder: folder,
    );
  }

  Future<Uint8List> readDecryptedBytes(VaultItem item) async {
    await initialize();
    if (!_items.any((stored) =>
        stored.id == item.id && stored.encryptedFilename == item.encryptedFilename)) {
      throw StateError('File not present in private vault index');
    }
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
    final clean = newName.replaceAll(RegExp(r'[\\/]'), '_').trim();
    if (clean.isEmpty || clean == '.' || clean == '..') return;
    final previous = _items[index];
    _items[index] = previous.copyWith(filename: clean);
    try { await _saveManifest(); } catch (_) { _items[index] = previous; rethrow; }
  }

  Future<void> moveItem(String id, String targetFolder) async {
    await initialize();
    final index = _items.indexWhere((i) => i.id == id);
    if (index == -1) return;
    final previous = _items[index];
    final oldFolders = Set<String>.from(_folders);
    final clean = targetFolder.trim();
    if (clean.isEmpty) return;
    _folders.add(clean);
    _items[index] = previous.copyWith(folder: clean);
    try { await _saveManifest(); } catch (_) {
      _items[index] = previous;
      _folders..clear()..addAll(oldFolders);
      rethrow;
    }
  }

  Future<void> deleteItem(String id) async {
    await initialize();
    final index = _items.indexWhere((i) => i.id == id);
    if (index == -1) return;
    final item = _items.removeAt(index);
    try { await _saveManifest(); } catch (_) {
      _items.insert(index, item);
      rethrow;
    }
    final dir = await _getDir();
    final file = File('${dir.path}/${item.encryptedFilename}');
    if (await file.exists()) await file.delete();
  }

  Future<void> addFolder(String folder) async {
    await initialize();
    final clean = folder.trim();
    if (clean.isEmpty || _folders.contains(clean)) return;
    _folders.add(clean);
    try { await _saveManifest(); } catch (_) { _folders.remove(clean); rethrow; }
  }

  Future<void> removeFolder(String folder) async {
    await initialize();
    if (folder == 'Root' || !_folders.contains(folder)) return;
    final previous = List<VaultItem>.from(_items);
    _folders.remove(folder);
    for (var i = 0; i < _items.length; i++) {
      if (_items[i].folder == folder) _items[i] = _items[i].copyWith(folder: 'Root');
    }
    try { await _saveManifest(); } catch (_) {
      _items..clear()..addAll(previous);
      _folders.add(folder);
      rethrow;
    }
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
      freeDeviceBytes: 0, // Available storage is unknown; do not fabricate it.
    );
  }

  Future<void> clearVault() async {
    // Destructive: caller must obtain explicit confirmation.
    await close();
    final dir = await _getDir();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      await dir.create(recursive: true);
    }
    if (customDir == null) {
      await const FlutterSecureStorage().delete(
        key: 'calculator.private_vault_v1.aes_key',
      );
    }
    _folders..clear()..addAll({'Root', 'Personal', 'Work', 'Financial'});
  }
}
