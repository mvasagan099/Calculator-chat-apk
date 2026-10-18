import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:calculator_messenger/core/security/backup_service.dart';
import 'package:calculator_messenger/core/security/local_cache.dart';

class FakeLocalCache implements LocalCache {
  FakeLocalCache([Map<String, dynamic>? initial])
      : data = initial ?? <String, dynamic>{};

  @override
  final Map<String, dynamic> data;

  int saveCount = 0;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> save() async {
    saveCount++;
  }

  @override
  Future<void> forget() async {
    data.clear();
  }

  @override
  Future<void> clear() async {
    data.clear();
  }
}

void main() {
  const testUserId = '11111111-1111-1111-1111-111111111111';
  const testPassword = 'CorrectHorseBatteryStaple#2026';

  late BackupService service;

  setUp(() {
    service = BackupService();
  });

  group('BackupService.createBackup', () {
    test('throws ArgumentError on empty or whitespace password', () async {
      final cache = FakeLocalCache();
      expect(
        () => service.createBackup(
          password: '',
          userId: testUserId,
          cache: cache,
        ),
        throwsArgumentError,
      );
      expect(
        () => service.createBackup(
          password: '   ',
          userId: testUserId,
          cache: cache,
        ),
        throwsArgumentError,
      );
    });

    test('exports encrypted envelope and does not leak plaintext in ciphertext', () async {
      final cache = FakeLocalCache({
        'conversations': [
          {
            'id': 'conv-1',
            'title': 'Secret Project',
            'updated_at': '2026-10-18T12:00:00Z',
          },
        ],
        'messages.conv-1': [
          {
            'id': 'msg-1',
            'content': 'Top secret conversation details',
            'created_at': '2026-10-18T12:00:00Z',
          },
        ],
        'wallpaper.conv-1': 'https://example.com/wall.jpg',
        'expiration.conv-1': 86400,
        // Outbox on the device creating backup
        'outbox': [
          {'id': 'pending-outbox-item', 'content': 'should not be in backup'},
        ],
      });

      final backupJson = await service.createBackup(
        password: testPassword,
        userId: testUserId,
        cache: cache,
      );

      final envelope = jsonDecode(backupJson) as Map<String, dynamic>;
      expect(envelope['format'], 'calculator_messenger_backup');
      expect(envelope['version'], 1);
      expect(envelope['user_id'], testUserId);

      // Verify KDF and cipher configuration
      final kdf = envelope['kdf'] as Map<String, dynamic>;
      expect(kdf['algorithm'], 'PBKDF2-HMAC-SHA256');
      expect(kdf['iterations'], 100000);
      expect(kdf['salt'], isNotEmpty);

      final cipher = envelope['cipher'] as Map<String, dynamic>;
      expect(cipher['algorithm'], 'AES-256-GCM');
      expect(cipher['nonce'], isNotEmpty);
      expect(cipher['tag'], isNotEmpty);
      expect(cipher['ciphertext'], isNotEmpty);

      // Verify summary matches count
      final summary = envelope['summary'] as Map<String, dynamic>;
      expect(summary['conversations'], 1);
      expect(summary['messages'], 1);

      // Ensure plaintext message and outbox words are not leaked anywhere in the backup string
      expect(backupJson, isNot(contains('Top secret conversation details')));
      expect(backupJson, isNot(contains('should not be in backup')));
    });
  });

  group('BackupService.restoreBackup', () {
    test('throws InvalidBackupPasswordException on empty password', () async {
      final cache = FakeLocalCache();
      expect(
        () => service.restoreBackup(
          password: '',
          backupJson: '{}',
          currentUserId: testUserId,
          cache: cache,
        ),
        throwsA(isA<InvalidBackupPasswordException>()),
      );
    });

    test('throws FormatException on malformed json or incorrect headers', () async {
      final cache = FakeLocalCache();
      expect(
        () => service.restoreBackup(
          password: testPassword,
          backupJson: 'not a json',
          currentUserId: testUserId,
          cache: cache,
        ),
        throwsA(isA<FormatException>()),
      );

      expect(
        () => service.restoreBackup(
          password: testPassword,
          backupJson: jsonEncode({'format': 'wrong_format', 'version': 1}),
          currentUserId: testUserId,
          cache: cache,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('restores conversations, messages, wallpapers, and expirations successfully', () async {
      final sourceCache = FakeLocalCache({
        'conversations': [
          {
            'id': 'conv-alpha',
            'title': 'General',
            'updated_at': '2026-10-18T10:00:00Z',
          },
        ],
        'messages.conv-alpha': [
          {
            'id': 'msg-alpha-1',
            'content': 'Hello from restored backup',
            'created_at': '2026-10-18T10:00:00Z',
          },
        ],
        'wallpaper.conv-alpha': 'custom-theme-wallpaper',
        'expiration.conv-alpha': 3600,
      });

      final backupJson = await service.createBackup(
        password: testPassword,
        userId: testUserId,
        cache: sourceCache,
      );

      final targetCache = FakeLocalCache();
      final result = await service.restoreBackup(
        password: testPassword,
        backupJson: backupJson,
        currentUserId: testUserId,
        cache: targetCache,
      );

      expect(result.conversationCount, 1);
      expect(result.messageCount, 1);
      expect(targetCache.saveCount, 1);

      // Verify restored content in target cache
      final restoredConvs = targetCache.data['conversations'] as List;
      expect(restoredConvs.length, 1);
      expect(restoredConvs.first['title'], 'General');

      final restoredMsgs = targetCache.data['messages.conv-alpha'] as List;
      expect(restoredMsgs.length, 1);
      expect(restoredMsgs.first['content'], 'Hello from restored backup');

      expect(targetCache.data['wallpaper.conv-alpha'], 'custom-theme-wallpaper');
      expect(targetCache.data['expiration.conv-alpha'], 3600);
    });

    test('fails closed with InvalidBackupPasswordException on wrong password', () async {
      final sourceCache = FakeLocalCache({
        'conversations': [
          {'id': 'c1', 'title': 'Private Chat'},
        ],
      });

      final backupJson = await service.createBackup(
        password: testPassword,
        userId: testUserId,
        cache: sourceCache,
      );

      final targetCache = FakeLocalCache();
      expect(
        () => service.restoreBackup(
          password: 'WrongPassword!',
          backupJson: backupJson,
          currentUserId: testUserId,
          cache: targetCache,
        ),
        throwsA(isA<InvalidBackupPasswordException>()),
      );
      expect(targetCache.data, isEmpty);
      expect(targetCache.saveCount, 0);
    });

    test('fails closed with InvalidBackupPasswordException when ciphertext is tampered', () async {
      final sourceCache = FakeLocalCache({
        'conversations': [
          {'id': 'c1', 'title': 'Private Chat'},
        ],
      });

      final backupJson = await service.createBackup(
        password: testPassword,
        userId: testUserId,
        cache: sourceCache,
      );

      final envelope = jsonDecode(backupJson) as Map<String, dynamic>;
      final cipher = envelope['cipher'] as Map<String, dynamic>;
      // Tamper one byte of ciphertext
      final rawBytes = base64Decode(cipher['ciphertext'] as String);
      rawBytes[0] ^= 0xFF;
      cipher['ciphertext'] = base64Encode(rawBytes);

      final tamperedJson = jsonEncode(envelope);
      final targetCache = FakeLocalCache();

      expect(
        () => service.restoreBackup(
          password: testPassword,
          backupJson: tamperedJson,
          currentUserId: testUserId,
          cache: targetCache,
        ),
        throwsA(isA<InvalidBackupPasswordException>()),
      );
      expect(targetCache.data, isEmpty);
    });

    test('STRICT: never overwrites or destroys pending offline outbox queue', () async {
      final sourceCache = FakeLocalCache({
        'conversations': [
          {
            'id': 'conv-1',
            'title': 'Server Conversations',
            'updated_at': '2026-10-18T10:00:00Z',
          },
        ],
        'messages.conv-1': [
          {
            'id': 'msg-1',
            'content': 'Historical message',
            'created_at': '2026-10-18T10:00:00Z',
          },
        ],
      });

      final backupJson = await service.createBackup(
        password: testPassword,
        userId: testUserId,
        cache: sourceCache,
      );

      // Target device has unsent offline outbox items
      final pendingOutbox = [
        {
          'id': 'offline-draft-1',
          'conversation_id': 'conv-1',
          'content': 'Queued message waiting for network',
          'enqueued_at': '2026-10-18T12:00:00Z',
        },
        {
          'id': 'offline-draft-2',
          'conversation_id': 'conv-2',
          'content': 'Second queued draft',
          'enqueued_at': '2026-10-18T12:01:00Z',
        },
      ];

      final targetCache = FakeLocalCache({
        'outbox': List<Map<String, dynamic>>.from(pendingOutbox),
      });

      await service.restoreBackup(
        password: testPassword,
        backupJson: backupJson,
        currentUserId: testUserId,
        cache: targetCache,
      );

      // Verify outbox was preserved with 100% integrity
      expect(targetCache.data['outbox'], isNotNull);
      final remainingOutbox = targetCache.data['outbox'] as List;
      expect(remainingOutbox.length, 2);
      expect(remainingOutbox[0]['id'], 'offline-draft-1');
      expect(remainingOutbox[0]['content'], 'Queued message waiting for network');
      expect(remainingOutbox[1]['id'], 'offline-draft-2');
      expect(remainingOutbox[1]['content'], 'Second queued draft');
    });

    test('deduplicates messages and sorts them newest first', () async {
      final sourceCache = FakeLocalCache({
        'conversations': [
          {'id': 'c1', 'title': 'Chat', 'updated_at': '2026-10-18T12:00:00Z'},
        ],
        'messages.c1': [
          {
            'id': 'msg-existing',
            'content': 'Already on device',
            'created_at': '2026-10-18T10:00:00Z',
          },
          {
            'id': 'msg-old',
            'content': 'Oldest restored message',
            'created_at': '2026-10-18T08:00:00Z',
          },
        ],
      });

      final backupJson = await service.createBackup(
        password: testPassword,
        userId: testUserId,
        cache: sourceCache,
      );

      final targetCache = FakeLocalCache({
        'conversations': [
          {'id': 'c1', 'title': 'Chat', 'updated_at': '2026-10-18T09:00:00Z'},
        ],
        'messages.c1': [
          {
            'id': 'msg-existing',
            'content': 'Already on device',
            'created_at': '2026-10-18T10:00:00Z',
          },
          {
            'id': 'msg-new',
            'content': 'Newest message on device',
            'created_at': '2026-10-18T11:00:00Z',
          },
        ],
      });

      final result = await service.restoreBackup(
        password: testPassword,
        backupJson: backupJson,
        currentUserId: testUserId,
        cache: targetCache,
      );

      expect(result.conversationCount, 1);
      final messages = (targetCache.data['messages.c1'] as List)
          .cast<Map<String, dynamic>>();

      // Total messages: msg-new (11:00), msg-existing (10:00), msg-old (08:00)
      expect(messages.length, 3);
      expect(messages[0]['id'], 'msg-new');
      expect(messages[1]['id'], 'msg-existing');
      expect(messages[2]['id'], 'msg-old');
    });
  });
}
