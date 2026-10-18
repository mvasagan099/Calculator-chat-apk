import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'local_cache.dart';
import 'local_retention.dart';

class InvalidBackupPasswordException implements Exception {
  const InvalidBackupPasswordException([this.message = 'Invalid password or corrupted backup file']);
  final String message;
  @override
  String toString() => message;
}

class BackupRestoreResult {
  const BackupRestoreResult({
    required this.conversationCount,
    required this.messageCount,
  });
  final int conversationCount;
  final int messageCount;
}

class BackupService {
  BackupService({AesGcm? cipher}) : _cipher = cipher ?? AesGcm.with256bits();
  final AesGcm _cipher;

  static Uint8List _randomBytes(int count) {
    final random = Random.secure();
    return Uint8List.fromList(List<int>.generate(count, (_) => random.nextInt(256)));
  }

  /// Exports an encrypted chat backup envelope using PBKDF2-HMAC-SHA256 + AES-256-GCM.
  /// Offline outbox queue is deliberately excluded to protect device-specific pending sends.
  Future<String> createBackup({
    required String password,
    required String userId,
    required LocalCache cache,
  }) async {
    if (password.trim().isEmpty) {
      throw ArgumentError('Backup password must not be empty');
    }

    final conversations = (cache.data['conversations'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    final messagesByCid = <String, List<Map<String, dynamic>>>{};
    var totalMessages = 0;
    for (final entry in cache.data.entries) {
      if (entry.key.startsWith('messages.')) {
        final rows = (entry.value as List? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .where((m) => !recordExpired(m, DateTime.now()))
            .toList();
        messagesByCid[entry.key] = rows;
        totalMessages += rows.length;
      }
    }

    final wallpapers = <String, String>{};
    final expirations = <String, int>{};
    for (final entry in cache.data.entries) {
      if (entry.key.startsWith('wallpaper.') && entry.value is String) {
        wallpapers[entry.key] = entry.value as String;
      } else if (entry.key.startsWith('expiration.') && entry.value is int) {
        expirations[entry.key] = entry.value as int;
      }
    }

    final payload = {
      'format': 'calculator_messenger_payload',
      'version': 1,
      'user_id': userId,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'conversations': conversations,
      'messages': messagesByCid,
      'wallpapers': wallpapers,
      'expirations': expirations,
    };

    final payloadBytes = utf8.encode(jsonEncode(payload));
    final salt = _randomBytes(16);
    final nonce = _randomBytes(12);

    final kdf = DartPbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 100000,
      bits: 256,
    );
    final secretKey = await kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );

    final aad = utf8.encode('backup:v1:$userId');
    final box = await _cipher.encrypt(
      payloadBytes,
      secretKey: secretKey,
      nonce: nonce,
      aad: aad,
    );

    final envelope = {
      'format': 'calculator_messenger_backup',
      'version': 1,
      'user_id': userId,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'kdf': {
        'algorithm': 'PBKDF2-HMAC-SHA256',
        'iterations': 100000,
        'salt': base64Encode(salt),
      },
      'cipher': {
        'algorithm': 'AES-256-GCM',
        'nonce': base64Encode(nonce),
        'tag': base64Encode(box.mac.bytes),
        'ciphertext': base64Encode(box.cipherText),
      },
      'summary': {
        'conversations': conversations.length,
        'messages': totalMessages,
      },
    };

    return const JsonEncoder.withIndent('  ').convert(envelope);
  }

  /// Restores an encrypted chat backup envelope.
  /// Verifies password authentication and safely merges historical conversations
  /// and messages WITHOUT destroying or modifying any pending offline outbox data.
  Future<BackupRestoreResult> restoreBackup({
    required String password,
    required String backupJson,
    required String currentUserId,
    required LocalCache cache,
  }) async {
    if (password.trim().isEmpty) {
      throw const InvalidBackupPasswordException('Please enter the backup password');
    }

    Map<String, dynamic> envelope;
    try {
      envelope = jsonDecode(backupJson) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('Invalid backup file format');
    }

    if (envelope['format'] != 'calculator_messenger_backup' || envelope['version'] != 1) {
      throw const FormatException('Unsupported backup version or format');
    }

    final kdfInfo = envelope['kdf'] as Map<String, dynamic>?;
    final cipherInfo = envelope['cipher'] as Map<String, dynamic>?;
    if (kdfInfo == null || cipherInfo == null) {
      throw const FormatException('Corrupted backup headers');
    }

    final salt = base64Decode(kdfInfo['salt'] as String);
    final iterations = (kdfInfo['iterations'] as num?)?.toInt() ?? 100000;
    final nonce = base64Decode(cipherInfo['nonce'] as String);
    final tag = base64Decode(cipherInfo['tag'] as String);
    final ciphertext = base64Decode(cipherInfo['ciphertext'] as String);
    final backupUserId = envelope['user_id'] as String? ?? currentUserId;

    final kdf = DartPbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
    final secretKey = await kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );

    List<int> decryptedBytes;
    try {
      final box = SecretBox(
        ciphertext,
        nonce: nonce,
        mac: Mac(tag),
      );
      decryptedBytes = await _cipher.decrypt(
        box,
        secretKey: secretKey,
        aad: utf8.encode('backup:v1:$backupUserId'),
      );
    } catch (_) {
      throw const InvalidBackupPasswordException('Incorrect password or corrupted backup file');
    }

    final payload = jsonDecode(utf8.decode(decryptedBytes)) as Map<String, dynamic>;
    final restoredConversations = (payload['conversations'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final restoredMessagesMap = (payload['messages'] as Map? ?? {})
        .cast<String, dynamic>();
    final restoredWallpapers = (payload['wallpapers'] as Map? ?? {})
        .cast<String, dynamic>();
    final restoredExpirations = (payload['expirations'] as Map? ?? {})
        .cast<String, dynamic>();

    // CRITICAL: Protect pending offline outbox items from being overwritten or destroyed.
    final existingOutbox = cache.data['outbox'];

    // 1. Merge conversations list
    final existingConversations = (cache.data['conversations'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final conversationsById = <String, Map<String, dynamic>>{
      for (final c in existingConversations) c['id'] as String: c,
    };
    for (final restored in restoredConversations) {
      final id = restored['id'] as String?;
      if (id == null) continue;
      if (!conversationsById.containsKey(id)) {
        conversationsById[id] = restored;
      } else {
        // Keep the one with newer updated_at
        final current = conversationsById[id]!;
        final currentTime = DateTime.tryParse(current['updated_at'] ?? '');
        final restoredTime = DateTime.tryParse(restored['updated_at'] ?? '');
        if (restoredTime != null && (currentTime == null || restoredTime.isAfter(currentTime))) {
          conversationsById[id] = {...current, ...restored};
        }
      }
    }
    cache.data['conversations'] = conversationsById.values.toList();

    // 2. Merge message histories
    var totalRestoredMessages = 0;
    for (final entry in restoredMessagesMap.entries) {
      final key = entry.key;
      final restoredList = (entry.value as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((m) => !recordExpired(m, DateTime.now()))
          .toList();

      final existingList = (cache.data[key] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      final messagesById = <String, Map<String, dynamic>>{
        for (final m in existingList) m['id'] as String: m,
      };

      for (final m in restoredList) {
        final id = m['id'] as String?;
        if (id == null) continue;
        messagesById.putIfAbsent(id, () => m);
      }

      final merged = messagesById.values.toList()
        ..sort((a, b) {
          final ta = DateTime.tryParse(a['created_at'] ?? '') ?? DateTime(1970);
          final tb = DateTime.tryParse(b['created_at'] ?? '') ?? DateTime(1970);
          return tb.compareTo(ta);
        });

      cache.data[key] = merged.take(200).toList();
      totalRestoredMessages += merged.length;
    }

    // 3. Merge wallpapers & expirations
    for (final entry in restoredWallpapers.entries) {
      cache.data.putIfAbsent(entry.key, () => entry.value);
    }
    for (final entry in restoredExpirations.entries) {
      cache.data.putIfAbsent(entry.key, () => entry.value);
    }

    // 4. Ensure existing outbox was completely preserved
    if (existingOutbox != null) {
      cache.data['outbox'] = existingOutbox;
    }

    // 5. Clean up any expired messages
    pruneLocalData(cache.data, DateTime.now());

    // 6. Persist merged data
    await cache.save();

    return BackupRestoreResult(
      conversationCount: conversationsById.length,
      messageCount: totalRestoredMessages,
    );
  }
}
