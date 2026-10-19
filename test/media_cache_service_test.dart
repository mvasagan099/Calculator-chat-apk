import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:calculator_messenger/core/security/media_cache_service.dart';
import 'package:calculator_messenger/core/security/pin_vault.dart';
import 'package:calculator_messenger/core/security/vault_service.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sqlite_test_factory.dart';

class MemorySecretStore implements SecretStore {
  final Map<String, String> _storage = {};

  @override
  Future<String?> read(String key) async => _storage[key];

  @override
  Future<void> write(String key, String value) async => _storage[key] = value;

  @override
  Future<void> delete(String key) async => _storage.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late MemorySecretStore secretStore;
  late MediaCacheService cacheService;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('media_cache_test_');
    secretStore = MemorySecretStore();
    cacheService = MediaCacheService(
      directory: tempDir,
      secretStore: secretStore,
      customFactory: sqliteTestFactory,
      maxCacheBytes: 1024 * 1024, // 1 MB for testing
    );
  });

  tearDown(() async {
    await cacheService.close();
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  group('MediaCacheService Layer 1 & 2 Verification', () {
    test('stores metadata in SQLite (Layer 1) and chunked AES-GCM encrypted file (Layer 2)', () async {
      final accountId = 'user-1';
      final objectPath = 'chats/chat-1/image-123.jpg';
      final testData = Uint8List.fromList(utf8.encode('Hello World Image Data! This is a test.'));

      final entry = await cacheService.storeMedia(
        accountId: accountId,
        chatId: 'chat-1',
        messageId: 'msg-1',
        mediaType: 'image',
        objectPath: objectPath,
        mimeType: 'image/jpeg',
        bytes: testData,
      );

      expect(entry.fileSize, testData.length);
      expect(entry.downloadStatus, 'completed');

      // Verify Layer 2: Encrypted file exists on disk and starts with 'MED2' magic header
      final encFile = File(entry.encryptedPath);
      expect(await encFile.exists(), isTrue);
      final rawDiskBytes = await encFile.readAsBytes();
      expect(rawDiskBytes.sublist(0, 4), [0x4D, 0x45, 0x44, 0x32]); // 'MED2'
      // Raw disk content must NOT contain the plaintext string
      expect(utf8.decode(rawDiskBytes, allowMalformed: true), isNot(contains('Hello World Image Data!')));

      // Verify Layer 1: SQLite metadata lookup
      final meta = await cacheService.getMetadata(accountId: accountId, objectPath: objectPath);
      expect(meta, isNotNull);
      expect(meta!.mimeType, 'image/jpeg');
      expect(meta.mediaType, 'image');

      // Verify Decryption & Retrieval
      final decrypted = await cacheService.getCachedBytes(accountId: accountId, objectPath: objectPath);
      expect(decrypted, isNotNull);
      expect(utf8.decode(decrypted!), 'Hello World Image Data! This is a test.');
    });

    test('getDecryptedStream streams plaintext without loading entire file to memory', () async {
      final accountId = 'user-stream';
      final objectPath = 'audio/voice-msg.m4a';
      // 100 KB payload across multiple 64 KB chunks
      final testData = Uint8List.fromList(List<int>.generate(100 * 1024, (i) => i % 256));

      await cacheService.storeMedia(
        accountId: accountId,
        mediaType: 'audio',
        objectPath: objectPath,
        mimeType: 'audio/m4a',
        bytes: testData,
      );

      final stream = await cacheService.getDecryptedStream(accountId: accountId, objectPath: objectPath);
      expect(stream, isNotNull);

      final chunks = <int>[];
      await for (final chunk in stream!) {
        chunks.addAll(chunk);
      }

      expect(chunks.length, testData.length);
      expect(Uint8List.fromList(chunks), testData);
    });

    test('deduplicates concurrent in-flight download requests to a single download', () async {
      final accountId = 'user-dedupe';
      final objectPath = 'docs/report.pdf';
      final testData = Uint8List.fromList(utf8.encode('PDF Content'));

      int downloadCalls = 0;

      Future<Uint8List> mockDownloader(void Function(double) onProgress) async {
        downloadCalls++;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return testData;
      }

      // Launch 3 simultaneous requests
      final futures = [
        cacheService.getOrDownload(
          accountId: accountId,
          mediaType: 'document',
          objectPath: objectPath,
          mimeType: 'application/pdf',
          downloader: mockDownloader,
        ),
        cacheService.getOrDownload(
          accountId: accountId,
          mediaType: 'document',
          objectPath: objectPath,
          mimeType: 'application/pdf',
          downloader: mockDownloader,
        ),
        cacheService.getOrDownload(
          accountId: accountId,
          mediaType: 'document',
          objectPath: objectPath,
          mimeType: 'application/pdf',
          downloader: mockDownloader,
        ),
      ];

      final results = await Future.wait(futures);
      expect(downloadCalls, 1); // Deduplicated! Only 1 actual download occurred.
      for (final res in results) {
        expect(res, testData);
      }

      // Subsequent call uses cache directly without downloader
      final cachedRes = await cacheService.getOrDownload(
        accountId: accountId,
        mediaType: 'document',
        objectPath: objectPath,
        mimeType: 'application/pdf',
        downloader: (prog) async {
          fail('Should not call downloader on cache hit');
        },
      );
      expect(cachedRes, testData);
    });

    test('LRU eviction prunes oldest non-pinned files when cache limit is exceeded', () async {
      final accountId = 'user-lru';
      // Create a cache service with 50 KB max limit
      final lruCache = MediaCacheService(
        directory: tempDir,
        secretStore: secretStore,
        customFactory: sqliteTestFactory,
        maxCacheBytes: 50 * 1024,
      );

      final payload20k = Uint8List(20 * 1024);

      // Store file 1 (oldest)
      await lruCache.storeMedia(
        accountId: accountId,
        mediaType: 'image',
        objectPath: 'img1.jpg',
        mimeType: 'image/jpeg',
        bytes: payload20k,
      );

      // Store file 2 (pinned, must NOT be evicted)
      await lruCache.storeMedia(
        accountId: accountId,
        mediaType: 'image',
        objectPath: 'img2_pinned.jpg',
        mimeType: 'image/jpeg',
        bytes: payload20k,
        isPinned: true,
      );

      // Store file 3 (pushing total to 60 KB, exceeding 50 KB limit)
      await lruCache.storeMedia(
        accountId: accountId,
        mediaType: 'image',
        objectPath: 'img3.jpg',
        mimeType: 'image/jpeg',
        bytes: payload20k,
      );

      await lruCache.prune(accountId);

      // File 1 should have been evicted
      final file1 = await lruCache.getCachedBytes(accountId: accountId, objectPath: 'img1.jpg');
      expect(file1, isNull);

      // File 2 (pinned) must still exist
      final file2 = await lruCache.getCachedBytes(accountId: accountId, objectPath: 'img2_pinned.jpg');
      expect(file2, isNotNull);

      // File 3 (newer) must still exist
      final file3 = await lruCache.getCachedBytes(accountId: accountId, objectPath: 'img3.jpg');
      expect(file3, isNotNull);

      await lruCache.close();
    });

    test('prune cleans up expired attachments automatically', () async {
      final accountId = 'user-expiry';
      final payload = Uint8List.fromList(utf8.encode('disappearing media'));

      await cacheService.storeMedia(
        accountId: accountId,
        mediaType: 'image',
        objectPath: 'expired.jpg',
        mimeType: 'image/jpeg',
        bytes: payload,
        expiresAt: DateTime.now().subtract(const Duration(minutes: 5)),
      );

      await cacheService.prune(accountId);

      final result = await cacheService.getCachedBytes(accountId: accountId, objectPath: 'expired.jpg');
      expect(result, isNull);
    });

    test('getStorageBreakdown reports per-media-category bytes accurately', () async {
      final accountId = 'user-breakdown';

      await cacheService.storeMedia(
        accountId: accountId,
        mediaType: 'image',
        objectPath: 'photo1.jpg',
        mimeType: 'image/jpeg',
        bytes: Uint8List(1000),
      );
      await cacheService.storeMedia(
        accountId: accountId,
        mediaType: 'video',
        objectPath: 'video1.mp4',
        mimeType: 'video/mp4',
        bytes: Uint8List(5000),
      );
      await cacheService.storeMedia(
        accountId: accountId,
        mediaType: 'audio',
        objectPath: 'voice1.m4a',
        mimeType: 'audio/m4a',
        bytes: Uint8List(2000),
      );
      await cacheService.storeMedia(
        accountId: accountId,
        mediaType: 'document',
        objectPath: 'doc1.pdf',
        mimeType: 'application/pdf',
        bytes: Uint8List(3000),
      );

      final breakdown = await cacheService.getStorageBreakdown(accountId);
      expect(breakdown.imageBytes, 1000);
      expect(breakdown.videoBytes, 5000);
      expect(breakdown.audioBytes, 2000);
      expect(breakdown.documentBytes, 3000);
      expect(breakdown.totalBytes, 11000);
      expect(breakdown.fileCount, 4);
    });

    test('clearConversationCache deletes only media for the chosen conversation', () async {
      final accountId = 'user-conv';

      await cacheService.storeMedia(
        accountId: accountId,
        chatId: 'chat-A',
        mediaType: 'image',
        objectPath: 'chatA_img.jpg',
        mimeType: 'image/jpeg',
        bytes: Uint8List(500),
      );
      await cacheService.storeMedia(
        accountId: accountId,
        chatId: 'chat-B',
        mediaType: 'image',
        objectPath: 'chatB_img.jpg',
        mimeType: 'image/jpeg',
        bytes: Uint8List(800),
      );

      await cacheService.clearConversationCache(accountId, 'chat-A');

      expect(await cacheService.getCachedBytes(accountId: accountId, objectPath: 'chatA_img.jpg'), isNull);
      expect(await cacheService.getCachedBytes(accountId: accountId, objectPath: 'chatB_img.jpg'), isNotNull);
    });
  });

  group('Private Vault Import & Self-Healing Tests', () {
    test('importChatAttachment copies media into Private Vault independently', () async {
      final vaultDir = await tempDir.createTemp('vault_test_');
      final vaultKey = SecretKey(List<int>.filled(32, 42));
      final vault = VaultService(
        customDir: vaultDir,
        customKey: vaultKey,
        factory: sqliteTestFactory,
      );
      await vault.initialize();

      final chatAttachmentBytes = Uint8List.fromList(utf8.encode('Secret Document from Chat'));
      final item = await vault.importChatAttachment(
        bytes: chatAttachmentBytes,
        filename: 'invoice.pdf',
        folder: 'Financial',
      );

      expect(item.filename, 'invoice.pdf');
      expect(item.folder, 'Financial');
      expect(item.contentHash, isNotNull);

      // Verify decrypted vault content
      final decrypted = await vault.readDecryptedBytes(item);
      expect(utf8.decode(decrypted), 'Secret Document from Chat');

      // Verify duplicate prevention using contentHash
      final dup = vault.findByHash(item.contentHash!);
      expect(dup, isNotNull);
      expect(dup!.id, item.id);

      await vault.close();
    });

    test('vault self-heals corrupted/missing index when encrypted files exist without lockout', () async {
      final vaultDir = await tempDir.createTemp('vault_heal_');
      final vaultKey = SecretKey(List<int>.filled(32, 99));

      // 1. Create an initial file in vault
      final vault1 = VaultService(
        customDir: vaultDir,
        customKey: vaultKey,
        factory: sqliteTestFactory,
      );
      await vault1.initialize();
      final item = await vault1.importBytes(
        bytes: Uint8List.fromList(utf8.encode('Essential vault file')),
        filename: 'secret.txt',
      );
      await vault1.close();

      // 2. Simulate SQLite index file corruption/deletion while .enc file remains
      final indexFile = File('${vaultDir.path}/vault_index.sqlite');
      if (await indexFile.exists()) {
        await indexFile.delete();
      }

      // 3. Re-initialize VaultService: Must self-heal orphaned files without throwing StateError!
      final vault2 = VaultService(
        customDir: vaultDir,
        customKey: vaultKey,
        factory: sqliteTestFactory,
      );

      // Should initialize successfully through self-healing
      await vault2.initialize();
      expect(vault2.items, isNotEmpty);
      expect(vault2.items.any((i) => i.encryptedFilename == item.encryptedFilename), isTrue);

      await vault2.close();
    });
  });
}
