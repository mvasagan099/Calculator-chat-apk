import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'pin_vault.dart';

class MediaCacheEntry {
  const MediaCacheEntry({
    required this.id,
    required this.accountId,
    this.chatId,
    this.messageId,
    this.mediaId,
    required this.mediaType,
    this.bucket = 'chat-media',
    required this.objectPath,
    this.remoteId,
    required this.encryptedPath,
    this.thumbnailEncryptedPath,
    required this.mimeType,
    required this.fileSize,
    this.contentHash,
    required this.downloadStatus,
    required this.createdAt,
    required this.lastAccessedAt,
    this.expiresAt,
    this.isPinned = false,
    this.retryCount = 0,
    this.downloadProgress = 0.0,
  });

  final String id;
  final String accountId;
  final String? chatId;
  final String? messageId;
  final String? mediaId;
  final String mediaType;
  final String bucket;
  final String objectPath;
  final String? remoteId;
  final String encryptedPath;
  final String? thumbnailEncryptedPath;
  final String mimeType;
  final int fileSize;
  final String? contentHash;
  final String downloadStatus; // 'pending', 'downloading', 'completed', 'failed'
  final DateTime createdAt;
  final DateTime lastAccessedAt;
  final DateTime? expiresAt;
  final bool isPinned;
  final int retryCount;
  final double downloadProgress;

  bool get isExpired {
    if (expiresAt == null) return false;
    return !expiresAt!.isAfter(DateTime.now());
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'account_id': accountId,
    'chat_id': chatId,
    'message_id': messageId,
    'media_id': mediaId,
    'media_type': mediaType,
    'bucket': bucket,
    'object_path': objectPath,
    'remote_id': remoteId,
    'encrypted_path': encryptedPath,
    'thumbnail_encrypted_path': thumbnailEncryptedPath,
    'mime_type': mimeType,
    'file_size': fileSize,
    'content_hash': contentHash,
    'download_status': downloadStatus,
    'created_at': createdAt.millisecondsSinceEpoch,
    'last_accessed_at': lastAccessedAt.millisecondsSinceEpoch,
    'expires_at': expiresAt?.millisecondsSinceEpoch,
    'is_pinned': isPinned ? 1 : 0,
    'retry_count': retryCount,
    'download_progress': downloadProgress,
  };

  factory MediaCacheEntry.fromMap(Map<String, dynamic> map) => MediaCacheEntry(
    id: map['id'] as String,
    accountId: map['account_id'] as String,
    chatId: map['chat_id'] as String?,
    messageId: map['message_id'] as String?,
    mediaId: map['media_id'] as String?,
    mediaType: map['media_type'] as String,
    bucket: (map['bucket'] as String?) ?? 'chat-media',
    objectPath: map['object_path'] as String,
    remoteId: map['remote_id'] as String?,
    encryptedPath: map['encrypted_path'] as String,
    thumbnailEncryptedPath: map['thumbnail_encrypted_path'] as String?,
    mimeType: map['mime_type'] as String,
    fileSize: (map['file_size'] as num).toInt(),
    contentHash: map['content_hash'] as String?,
    downloadStatus: (map['download_status'] as String?) ?? 'completed',
    createdAt: DateTime.fromMillisecondsSinceEpoch((map['created_at'] as num).toInt()),
    lastAccessedAt: DateTime.fromMillisecondsSinceEpoch((map['last_accessed_at'] as num).toInt()),
    expiresAt: map['expires_at'] != null
        ? DateTime.fromMillisecondsSinceEpoch((map['expires_at'] as num).toInt())
        : null,
    isPinned: (map['is_pinned'] as int? ?? 0) == 1,
    retryCount: (map['retry_count'] as int? ?? 0),
    downloadProgress: (map['download_progress'] as num?)?.toDouble() ?? 0.0,
  );

  MediaCacheEntry copyWith({
    String? downloadStatus,
    DateTime? lastAccessedAt,
    DateTime? expiresAt,
    bool? isPinned,
    int? retryCount,
    double? downloadProgress,
    String? thumbnailEncryptedPath,
    String? contentHash,
  }) => MediaCacheEntry(
    id: id,
    accountId: accountId,
    chatId: chatId,
    messageId: messageId,
    mediaId: mediaId,
    mediaType: mediaType,
    bucket: bucket,
    objectPath: objectPath,
    remoteId: remoteId,
    encryptedPath: encryptedPath,
    thumbnailEncryptedPath: thumbnailEncryptedPath ?? this.thumbnailEncryptedPath,
    mimeType: mimeType,
    fileSize: fileSize,
    contentHash: contentHash ?? this.contentHash,
    downloadStatus: downloadStatus ?? this.downloadStatus,
    createdAt: createdAt,
    lastAccessedAt: lastAccessedAt ?? this.lastAccessedAt,
    expiresAt: expiresAt ?? this.expiresAt,
    isPinned: isPinned ?? this.isPinned,
    retryCount: retryCount ?? this.retryCount,
    downloadProgress: downloadProgress ?? this.downloadProgress,
  );
}

class MediaStorageStats {
  const MediaStorageStats({
    required this.totalBytes,
    required this.imageBytes,
    required this.videoBytes,
    required this.audioBytes,
    required this.documentBytes,
    required this.fileCount,
  });

  final int totalBytes;
  final int imageBytes;
  final int videoBytes;
  final int audioBytes;
  final int documentBytes;
  final int fileCount;
}

/// Centralized, encrypted, offline-first media caching service.
/// Uses 2 layers:
/// Layer 1: SQLite metadata for fast indexed queries, account isolation, and LRU eviction.
/// Layer 2: Encrypted app-private files using AES-256-GCM with per-account key protection.
class MediaCacheService {
  MediaCacheService({
    this.directory,
    SecretStore? secretStore,
    this.customFactory,
    DateTime Function()? clock,
    int? maxCacheBytes,
  }) : store = secretStore ?? const DeviceSecretStore(),
       clock = clock ?? DateTime.now,
       _instanceMaxCacheBytes = maxCacheBytes;

  static int globalMaxCacheBytes = 2 * 1024 * 1024 * 1024;

  final Directory? directory;
  final SecretStore store;
  final DatabaseFactory? customFactory;
  DatabaseFactory get factory => customFactory ?? databaseFactory;
  final DateTime Function() clock;
  final int? _instanceMaxCacheBytes;
  int get maxCacheBytes => _instanceMaxCacheBytes ?? globalMaxCacheBytes;
  final AesGcm _cipher = AesGcm.with256bits();

  static const int chunkSize = 65536; // 64 KB streaming chunks
  static const List<int> magicBytes = [0x4D, 0x45, 0x44, 0x32]; // 'MED2'

  final Map<String, Database> _dbHandles = {};
  final Map<String, SecretKey> _keys = {};
  final Map<String, Future<Uint8List>> _inFlightDownloads = {};
  final Set<String> _inUseMediaIds = {};

  Future<String> _hash(String value) async {
    final bytes = (await Sha256().hash(utf8.encode(value))).bytes;
    return bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<Directory> _rootDir() async {
    if (directory != null) return directory!;
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/encrypted-chat-media-v2');
  }

  Future<Directory> _accountDir(String accountId) async {
    final root = await _rootDir();
    final hashed = await _hash(accountId);
    final dir = Directory('${root.path}/$hashed');
    await dir.create(recursive: true);
    return dir;
  }

  Future<SecretKey> _getOrCreateKey(String accountId) async {
    if (_keys.containsKey(accountId)) return _keys[accountId]!;
    final keyIdentifier = 'chat.media.cache.key.v2.${await _hash(accountId)}';
    var encoded = await store.read(keyIdentifier);
    if (encoded == null) {
      final newKey = await _cipher.newSecretKey();
      encoded = base64Encode(await newKey.extractBytes());
      await store.write(keyIdentifier, encoded);
    }
    final bytes = base64Decode(encoded);
    if (bytes.length != 32) throw StateError('Invalid encryption key for media cache');
    final key = SecretKey(bytes);
    _keys[accountId] = key;
    return key;
  }

  static Future<void> _applyPragma(Database database, String pragma) async {
    try {
      await database.rawQuery(pragma);
    } catch (_) {
      try {
        await database.execute(pragma);
      } catch (_) {
        // Optional PRAGMA unsupported by this engine; safely ignored.
      }
    }
  }

  Future<Database> _getDatabase(String accountId) async {
    if (_dbHandles.containsKey(accountId)) return _dbHandles[accountId]!;
    final dir = await _accountDir(accountId);
    final dbPath = '${dir.path}/metadata.sqlite';

    final db = await factory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        singleInstance: false,
        onConfigure: (database) async {
          await _applyPragma(database, 'PRAGMA secure_delete=ON');
        },
        onCreate: (database, _) async {
          await database.execute('''
            CREATE TABLE IF NOT EXISTS media_cache_entries (
              id TEXT PRIMARY KEY,
              account_id TEXT NOT NULL,
              chat_id TEXT,
              message_id TEXT,
              media_id TEXT,
              media_type TEXT NOT NULL,
              bucket TEXT NOT NULL DEFAULT 'chat-media',
              object_path TEXT NOT NULL,
              remote_id TEXT,
              encrypted_path TEXT NOT NULL,
              thumbnail_encrypted_path TEXT,
              mime_type TEXT NOT NULL,
              file_size INTEGER NOT NULL,
              content_hash TEXT,
              download_status TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              last_accessed_at INTEGER NOT NULL,
              expires_at INTEGER,
              is_pinned INTEGER NOT NULL DEFAULT 0,
              retry_count INTEGER NOT NULL DEFAULT 0,
              download_progress REAL NOT NULL DEFAULT 0.0
            ) WITHOUT ROWID
          ''');
          await database.execute(
            'CREATE INDEX IF NOT EXISTS idx_media_cache_account_obj ON media_cache_entries (account_id, object_path)',
          );
          await database.execute(
            'CREATE INDEX IF NOT EXISTS idx_media_cache_account_lru ON media_cache_entries (account_id, is_pinned, last_accessed_at)',
          );
          await database.execute(
            'CREATE INDEX IF NOT EXISTS idx_media_cache_chat ON media_cache_entries (account_id, chat_id)',
          );
        },
      ),
    );
    _dbHandles[accountId] = db;
    return db;
  }

  void markMediaInUse(String objectPath) {
    _inUseMediaIds.add(objectPath);
  }

  void releaseMediaInUse(String objectPath) {
    _inUseMediaIds.remove(objectPath);
  }

  /// Calculates stable content hash (SHA-256) of bytes.
  Future<String> calculateHash(Uint8List bytes) async {
    final digest = await Sha256().hash(bytes);
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Encrypts bytes using chunked streaming AES-256-GCM.
  Future<void> _encryptToFile({
    required Uint8List bytes,
    required File targetFile,
    required SecretKey key,
    required String accountId,
    required String objectPath,
    DateTime? expiresAt,
  }) async {
    final tempFile = File('${targetFile.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    final sink = tempFile.openWrite();

    try {
      // 1. Magic bytes (4 bytes)
      sink.add(magicBytes);

      // 2. Header metadata: chunk size (4 bytes), total bytes (8 bytes), expiresAt ms (8 bytes)
      final headerData = ByteData(20);
      headerData.setUint32(0, chunkSize, Endian.big);
      headerData.setInt64(4, bytes.length, Endian.big);
      headerData.setInt64(12, expiresAt?.millisecondsSinceEpoch ?? 0, Endian.big);
      sink.add(headerData.buffer.asUint8List());

      // 3. Encrypt in chunks
      var offset = 0;
      var chunkIndex = 0;
      while (offset < bytes.length) {
        final end = (offset + chunkSize).clamp(0, bytes.length);
        final chunk = bytes.sublist(offset, end);
        final aad = utf8.encode('chat-media-v2|$accountId|$objectPath|$chunkIndex');

        final secretBox = await _cipher.encrypt(
          chunk,
          secretKey: key,
          aad: aad,
        );

        // Chunk envelope: nonce (12 bytes) + mac (16 bytes) + ciphertext (chunk length bytes)
        sink.add(secretBox.nonce);
        sink.add(secretBox.mac.bytes);
        sink.add(secretBox.cipherText);

        offset = end;
        chunkIndex++;
      }

      await sink.flush();
      await sink.close();

      // Atomic rename
      await tempFile.rename(targetFile.path);
    } catch (_) {
      try {
        await sink.close();
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// Decrypts file using chunked streaming AES-256-GCM.
  Future<Uint8List> _decryptFromFile({
    required File file,
    required SecretKey key,
    required String accountId,
    required String objectPath,
    int? expectedSize,
  }) async {
    final raw = await file.readAsBytes();

    // Check for V2 format magic bytes
    if (raw.length >= 24 &&
        raw[0] == magicBytes[0] &&
        raw[1] == magicBytes[1] &&
        raw[2] == magicBytes[2] &&
        raw[3] == magicBytes[3]) {
      final header = ByteData.sublistView(raw, 4, 24);
      final sizePerChunk = header.getUint32(0, Endian.big);
      final totalSize = header.getInt64(4, Endian.big);
      final expiryMs = header.getInt64(12, Endian.big);

      if (expiryMs > 0 && !DateTime.fromMillisecondsSinceEpoch(expiryMs).isAfter(clock())) {
        throw StateError('Media cache entry has expired');
      }

      final output = BytesBuilder(copy: false);
      var offset = 24;
      var chunkIndex = 0;

      while (offset < raw.length) {
        if (offset + 28 > raw.length) throw const FormatException('Corrupted chunk header');
        final nonce = raw.sublist(offset, offset + 12);
        final mac = Mac(raw.sublist(offset + 12, offset + 28));
        offset += 28;

        final remainingPlain = totalSize - output.length;
        final cipherLen = (remainingPlain > sizePerChunk) ? sizePerChunk : remainingPlain;
        if (offset + cipherLen > raw.length) throw const FormatException('Corrupted chunk payload');

        final cipherText = raw.sublist(offset, offset + cipherLen);
        offset += cipherLen;

        final aad = utf8.encode('chat-media-v2|$accountId|$objectPath|$chunkIndex');
        final plainChunk = await _cipher.decrypt(
          SecretBox(cipherText, nonce: nonce, mac: mac),
          secretKey: key,
          aad: aad,
        );
        output.add(plainChunk);
        chunkIndex++;
      }

      final result = output.takeBytes();
      if (expectedSize != null && result.length != expectedSize) {
        throw const FormatException('Decrypted size mismatch');
      }
      return result;
    }

    // Fallback: Check for legacy V1 format (8 bytes expiry + 12 nonce + 16 mac + payload)
    if (raw.length >= 36) {
      final expiry = ByteData.sublistView(raw, 0, 8).getInt64(0, Endian.big);
      if (expiry > 0 && !DateTime.fromMillisecondsSinceEpoch(expiry).isAfter(clock())) {
        throw StateError('Media cache entry has expired');
      }
      final nonce = raw.sublist(8, 20);
      final mac = Mac(raw.sublist(20, 36));
      final cipherText = raw.sublist(36);
      final aad = 'chat-media-v1|$accountId|$objectPath|${raw.length - 36}|$expiry';

      final decrypted = await _cipher.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: mac),
        secretKey: key,
        aad: utf8.encode(aad),
      );
      return Uint8List.fromList(decrypted);
    }

    throw const FormatException('Unknown encrypted media cache format');
  }

  /// Looks up the cached media entry in SQLite metadata.
  Future<MediaCacheEntry?> getMetadata({
    required String accountId,
    required String objectPath,
  }) async {
    final db = await _getDatabase(accountId);
    final rows = await db.query(
      'media_cache_entries',
      where: 'account_id = ? AND object_path = ?',
      whereArgs: [accountId, objectPath],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return MediaCacheEntry.fromMap(rows.first);
  }

  /// Verifies if a valid, unexpired, intact cached copy exists locally.
  Future<bool> hasValidCache({
    required String accountId,
    required String objectPath,
  }) async {
    final meta = await getMetadata(accountId: accountId, objectPath: objectPath);
    if (meta == null || meta.downloadStatus != 'completed') return false;
    if (meta.isExpired) return false;
    final file = File(meta.encryptedPath);
    return await file.exists();
  }

  /// Decrypts and returns the cached media bytes without touching the network.
  /// Returns null if missing, invalid, or expired.
  Future<Uint8List?> getCachedBytes({
    required String accountId,
    required String objectPath,
  }) async {
    final meta = await getMetadata(accountId: accountId, objectPath: objectPath);
    if (meta == null || meta.downloadStatus != 'completed') return null;

    if (meta.isExpired) {
      await evict(accountId: accountId, objectPath: objectPath);
      return null;
    }

    final file = File(meta.encryptedPath);
    if (!await file.exists()) {
      await evict(accountId: accountId, objectPath: objectPath);
      return null;
    }

    try {
      final key = await _getOrCreateKey(accountId);
      final bytes = await _decryptFromFile(
        file: file,
        key: key,
        accountId: accountId,
        objectPath: objectPath,
        expectedSize: meta.fileSize,
      );

      // Update last-accessed timestamp for LRU tracking
      final db = await _getDatabase(accountId);
      await db.update(
        'media_cache_entries',
        {'last_accessed_at': clock().millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [meta.id],
      );

      return bytes;
    } catch (_) {
      // If decryption fails due to corruption, remove corrupt cache record
      await evict(accountId: accountId, objectPath: objectPath);
      return null;
    }
  }

  /// Decrypts and provides an app-private decrypted temporary file for playback/viewing.
  /// Caller is responsible for deleting the temporary file when finished.
  Future<File?> getDecryptedTemporaryFile({
    required String accountId,
    required String objectPath,
    String? extension,
  }) async {
    final bytes = await getCachedBytes(accountId: accountId, objectPath: objectPath);
    if (bytes == null) return null;

    final tempDir = await getTemporaryDirectory();
    final ext = extension ?? (objectPath.contains('.') ? objectPath.split('.').last : 'bin');
    final tempFile = File('${tempDir.path}/media_${const Uuid().v4()}.$ext');
    await tempFile.writeAsBytes(bytes, flush: true);
    return tempFile;
  }

  /// Streams decrypted plaintext chunks of an encrypted media file.
  Future<Stream<List<int>>?> getDecryptedStream({
    required String accountId,
    required String objectPath,
  }) async {
    final meta = await getMetadata(accountId: accountId, objectPath: objectPath);
    if (meta == null) return null;
    final file = File(meta.encryptedPath);
    if (!await file.exists()) return null;

    final key = await _getOrCreateKey(accountId);
    final raw = await file.readAsBytes();

    Stream<List<int>> generator() async* {
      if (raw.length >= 24 &&
          raw[0] == magicBytes[0] &&
          raw[1] == magicBytes[1] &&
          raw[2] == magicBytes[2] &&
          raw[3] == magicBytes[3]) {
        final header = ByteData.sublistView(raw, 4, 24);
        final sizePerChunk = header.getUint32(0, Endian.big);
        final totalSize = header.getInt64(4, Endian.big);
        var offset = 24;
        var chunkIndex = 0;
        var yieldedBytes = 0;

        while (offset < raw.length) {
          if (offset + 28 > raw.length) throw const FormatException('Corrupted chunk header');
          final nonce = raw.sublist(offset, offset + 12);
          final mac = Mac(raw.sublist(offset + 12, offset + 28));
          offset += 28;

          final remainingPlain = totalSize - yieldedBytes;
          final cipherLen = (remainingPlain > sizePerChunk) ? sizePerChunk : remainingPlain;
          if (offset + cipherLen > raw.length) throw const FormatException('Corrupted chunk payload');

          final cipherText = raw.sublist(offset, offset + cipherLen);
          offset += cipherLen;

          final aad = utf8.encode('chat-media-v2|$accountId|$objectPath|$chunkIndex');
          final plainChunk = await _cipher.decrypt(
            SecretBox(cipherText, nonce: nonce, mac: mac),
            secretKey: key,
            aad: aad,
          );
          yieldedBytes += plainChunk.length;
          yield plainChunk;
          chunkIndex++;
        }
      } else {
        final decrypted = await _decryptFromFile(
          file: file,
          key: key,
          accountId: accountId,
          objectPath: objectPath,
          expectedSize: meta.fileSize,
        );
        yield decrypted;
      }
    }

    return generator();
  }

  /// Stores and encrypts downloaded or sent media bytes into the cache.
  Future<MediaCacheEntry> storeMedia({
    required String accountId,
    String? chatId,
    String? messageId,
    String? mediaId,
    required String mediaType,
    String bucket = 'chat-media',
    required String objectPath,
    String? remoteId,
    required String mimeType,
    required Uint8List bytes,
    DateTime? expiresAt,
    bool isPinned = false,
    Uint8List? thumbnailBytes,
  }) async {
    final dir = await _accountDir(accountId);
    final key = await _getOrCreateKey(accountId);
    final hashName = await _hash('$accountId|$objectPath|$mimeType|${bytes.length}');
    final targetFile = File('${dir.path}/$hashName.enc');

    await _encryptToFile(
      bytes: bytes,
      targetFile: targetFile,
      key: key,
      accountId: accountId,
      objectPath: objectPath,
      expiresAt: expiresAt,
    );

    String? thumbPath;
    if (thumbnailBytes != null && thumbnailBytes.isNotEmpty) {
      final thumbFile = File('${dir.path}/${hashName}_thumb.enc');
      await _encryptToFile(
        bytes: thumbnailBytes,
        targetFile: thumbFile,
        key: key,
        accountId: accountId,
        objectPath: '$objectPath/thumb',
        expiresAt: expiresAt,
      );
      thumbPath = thumbFile.path;
    }

    final contentHash = await calculateHash(bytes);
    final now = clock();

    final entry = MediaCacheEntry(
      id: const Uuid().v4(),
      accountId: accountId,
      chatId: chatId,
      messageId: messageId,
      mediaId: mediaId,
      mediaType: mediaType,
      bucket: bucket,
      objectPath: objectPath,
      remoteId: remoteId,
      encryptedPath: targetFile.path,
      thumbnailEncryptedPath: thumbPath,
      mimeType: mimeType,
      fileSize: bytes.length,
      contentHash: contentHash,
      downloadStatus: 'completed',
      createdAt: now,
      lastAccessedAt: now,
      expiresAt: expiresAt,
      isPinned: isPinned,
      retryCount: 0,
      downloadProgress: 1.0,
    );

    final db = await _getDatabase(accountId);
    await db.insert(
      'media_cache_entries',
      entry.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    // Run bounded LRU check asynchronously
    unawaited(prune(accountId).catchError((_) {}));

    return entry;
  }

  /// Deduplicated download helper:
  /// If already in cache, returns immediately.
  /// If currently downloading by another widget, awaits the same Future.
  /// If not cached, executes [downloader], encrypts and stores the result.
  Future<Uint8List> getOrDownload({
    required String accountId,
    String? chatId,
    String? messageId,
    String? mediaId,
    required String mediaType,
    String bucket = 'chat-media',
    required String objectPath,
    required String mimeType,
    int? expectedSize,
    DateTime? expiresAt,
    bool isPinned = false,
    required Future<Uint8List> Function(void Function(double) onProgress) downloader,
    void Function(double)? onProgress,
  }) async {
    // 1. Check existing local cache
    final cached = await getCachedBytes(accountId: accountId, objectPath: objectPath);
    if (cached != null) {
      onProgress?.call(1.0);
      return cached;
    }

    // 2. Deduplicate concurrent requests
    final dedupeKey = '$accountId:$objectPath';
    if (_inFlightDownloads.containsKey(dedupeKey)) {
      return await _inFlightDownloads[dedupeKey]!;
    }

    final completer = Completer<Uint8List>();
    _inFlightDownloads[dedupeKey] = completer.future;

    try {
      final downloadedBytes = await downloader((progress) {
        onProgress?.call(progress);
      });

      if (expectedSize != null && downloadedBytes.length != expectedSize) {
        throw FormatException('Downloaded size ${downloadedBytes.length} != expected $expectedSize');
      }

      await storeMedia(
        accountId: accountId,
        chatId: chatId,
        messageId: messageId,
        mediaId: mediaId,
        mediaType: mediaType,
        bucket: bucket,
        objectPath: objectPath,
        mimeType: mimeType,
        bytes: downloadedBytes,
        expiresAt: expiresAt,
        isPinned: isPinned,
      );

      completer.complete(downloadedBytes);
      return downloadedBytes;
    } catch (error, stack) {
      completer.completeError(error, stack);
      rethrow;
    } finally {
      _inFlightDownloads.remove(dedupeKey);
    }
  }

  /// Evicts a specific media item from cache and SQLite.
  Future<void> evict({
    required String accountId,
    required String objectPath,
  }) async {
    final meta = await getMetadata(accountId: accountId, objectPath: objectPath);
    if (meta == null) return;

    final db = await _getDatabase(accountId);
    await db.delete(
      'media_cache_entries',
      where: 'account_id = ? AND object_path = ?',
      whereArgs: [accountId, objectPath],
    );

    try {
      final file = File(meta.encryptedPath);
      if (await file.exists()) await file.delete();
      if (meta.thumbnailEncryptedPath != null) {
        final thumbFile = File(meta.thumbnailEncryptedPath!);
        if (await thumbFile.exists()) await thumbFile.delete();
      }
    } catch (_) {}
  }

  /// LRU Eviction: Removes expired files first, then evicts least-recently-used files
  /// to stay within [maxCacheBytes]. Never touches pinned files, in-use files, or Private Vault files.
  Future<void> prune(String accountId) async {
    final db = await _getDatabase(accountId);
    final nowMs = clock().millisecondsSinceEpoch;

    // 1. Delete expired entries
    final expiredRows = await db.query(
      'media_cache_entries',
      where: 'account_id = ? AND expires_at IS NOT NULL AND expires_at < ?',
      whereArgs: [accountId, nowMs],
    );
    for (final row in expiredRows) {
      final path = row['object_path'] as String;
      if (!_inUseMediaIds.contains(path)) {
        await evict(accountId: accountId, objectPath: path);
      }
    }

    // 2. Enforce max cache size limit
    final sumResult = await db.rawQuery(
      'SELECT SUM(file_size) as total FROM media_cache_entries WHERE account_id = ? AND download_status = ?',
      [accountId, 'completed'],
    );
    var totalBytes = (sumResult.first['total'] as num?)?.toInt() ?? 0;

    if (totalBytes > maxCacheBytes) {
      // Find oldest accessed non-pinned entries
      final candidates = await db.query(
        'media_cache_entries',
        where: 'account_id = ? AND is_pinned = 0 AND download_status = ?',
        whereArgs: [accountId, 'completed'],
        orderBy: 'last_accessed_at ASC',
      );

      for (final row in candidates) {
        if (totalBytes <= maxCacheBytes) break;
        final path = row['object_path'] as String;
        if (_inUseMediaIds.contains(path)) continue; // In-use protection

        final size = (row['file_size'] as num).toInt();
        await evict(accountId: accountId, objectPath: path);
        totalBytes -= size;
      }
    }
  }

  /// Clears all downloaded chat media for an account, keeping metadata schema intact.
  Future<void> clearDownloadedChatMedia(String accountId) async {
    final db = await _getDatabase(accountId);
    final rows = await db.query(
      'media_cache_entries',
      where: 'account_id = ?',
      whereArgs: [accountId],
    );

    for (final row in rows) {
      try {
        final path = row['encrypted_path'] as String?;
        if (path != null) {
          final file = File(path);
          if (await file.exists()) await file.delete();
        }
        final thumbPath = row['thumbnail_encrypted_path'] as String?;
        if (thumbPath != null) {
          final thumb = File(thumbPath);
          if (await thumb.exists()) await thumb.delete();
        }
      } catch (_) {}
    }

    await db.delete(
      'media_cache_entries',
      where: 'account_id = ?',
      whereArgs: [accountId],
    );
  }

  /// Clears cached media for a specific conversation.
  Future<void> clearConversationCache(String accountId, String chatId) async {
    final db = await _getDatabase(accountId);
    final rows = await db.query(
      'media_cache_entries',
      where: 'account_id = ? AND chat_id = ?',
      whereArgs: [accountId, chatId],
    );

    for (final row in rows) {
      final objPath = row['object_path'] as String;
      await evict(accountId: accountId, objectPath: objPath);
    }
  }

  /// Clears temporary downloaded files from temporary directory.
  Future<void> clearTemporaryCache() async {
    final tempDir = await getTemporaryDirectory();
    if (await tempDir.exists()) {
      await for (final file in tempDir.list(followLinks: false)) {
        try {
          await file.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// Clears cached thumbnails only.
  Future<void> clearThumbnails(String accountId) async {
    final db = await _getDatabase(accountId);
    final rows = await db.query(
      'media_cache_entries',
      where: 'account_id = ? AND thumbnail_encrypted_path IS NOT NULL',
      whereArgs: [accountId],
    );

    for (final row in rows) {
      final thumbPath = row['thumbnail_encrypted_path'] as String?;
      if (thumbPath != null) {
        final f = File(thumbPath);
        if (await f.exists()) await f.delete();
      }
    }

    await db.update(
      'media_cache_entries',
      {'thumbnail_encrypted_path': null},
      where: 'account_id = ?',
      whereArgs: [accountId],
    );
  }

  /// Computes storage breakdown by media category for this account.
  Future<MediaStorageStats> getStorageBreakdown(String accountId) async {
    final db = await _getDatabase(accountId);
    final rows = await db.rawQuery('''
      SELECT media_type, SUM(file_size) as total, COUNT(*) as count
      FROM media_cache_entries
      WHERE account_id = ? AND download_status = 'completed'
      GROUP BY media_type
    ''', [accountId]);

    var totalBytes = 0;
    var imageBytes = 0;
    var videoBytes = 0;
    var audioBytes = 0;
    var documentBytes = 0;
    var fileCount = 0;

    for (final row in rows) {
      final type = (row['media_type'] as String?)?.toLowerCase() ?? '';
      final bytes = (row['total'] as num?)?.toInt() ?? 0;
      final count = (row['count'] as num?)?.toInt() ?? 0;

      totalBytes += bytes;
      fileCount += count;

      if (type.contains('image')) {
        imageBytes += bytes;
      } else if (type.contains('video')) {
        videoBytes += bytes;
      } else if (type.contains('audio') || type.contains('voice')) {
        audioBytes += bytes;
      } else {
        documentBytes += bytes;
      }
    }

    return MediaStorageStats(
      totalBytes: totalBytes,
      imageBytes: imageBytes,
      videoBytes: videoBytes,
      audioBytes: audioBytes,
      documentBytes: documentBytes,
      fileCount: fileCount,
    );
  }

  /// Closes database handles and keys for this service.
  Future<void> close() async {
    for (final db in _dbHandles.values) {
      await db.close();
    }
    _dbHandles.clear();
    _keys.clear();
    _inFlightDownloads.clear();
    _inUseMediaIds.clear();
  }
}
