import 'dart:io';
import 'dart:typed_data';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:calculator_messenger/features/media/media_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:calculator_messenger/core/security/local_retention.dart';
import 'package:calculator_messenger/core/security/private_media_files.dart';
import 'package:calculator_messenger/core/security/encrypted_cache.dart';
import 'pin_vault_test.dart' show MemorySecrets;

void main() {
  test('visual media cannot mint a stale or overlong bearer signed URL', () async {
    final client = SupabaseClient('https://fixture.supabase.co', 'fixture');
    for (final mime in ['image/jpeg', 'video/mp4']) {
      expect(() => MediaService(client).signedUrl({'mime_type': mime, 'object_path': 'private',
        'media_expires_at': DateTime.now().add(const Duration(hours: 48)).toIso8601String()}), throwsStateError);
    }
    await client.dispose();
  });
  for (final mime in ['image/jpeg', 'video/mp4']) {
    test('$mime expires attachment without deleting text history, and drops stale retry', () {
      final now = DateTime.utc(2026, 10, 16);
      final media = {'mime_type': mime, 'object_path': 'private/path', 'media_expires_at': now.toIso8601String()};
      final data = <String, dynamic>{
        'messages.self': [ {'id': 'keep', 'body': 'Caption survives', 'attachment': media, 'reply_to': 'text'} ],
        'outbox': [ {'id': 'stale', 'attachment': media} ],
      };
      expect(pruneLocalData(data, now), isTrue);
      expect(data['messages.self'][0]['body'], 'Caption survives');
      expect(data['messages.self'][0]['reply_to'], 'text');
      expect(data['messages.self'][0]['attachment'], isNull);
      expect(data['messages.self'][0]['message_attachments'], isEmpty);
      expect(data['outbox'], isEmpty);
      expect(pruneLocalData(data, now), isFalse);
    });
  }
  test('audio/documents retain their existing policy and malformed visual metadata fails closed', () {
    final now = DateTime.now();
    for (final mime in ['audio/ogg', 'application/pdf']) {
      expect(visualAttachmentExpired({'mime_type': mime}, now), isFalse);
    }
    expect(visualAttachmentExpired({'mime_type': 'image/jpeg'}, now), isTrue);
    expect(visualAttachmentExpired({'mime_type': 'video/mp4', 'media_expires_at': 'invalid'}, now), isTrue);
  });
  test('restart permanently removes expired attachment references from encrypted cache', () async {
    final root = await Directory.systemTemp.createTemp('media-retention-cache');
    try {
      var now = DateTime.utc(2026, 10, 16);
      final secrets = MemorySecrets();
      final first = EncryptedCache('owner', secrets, directory: root, clock: () => now);
      await first.initialize();
      first.data['messages.self'] = [{'id': 'photo', 'body': 'Keep text', 'message_attachments': [
        {'mime_type': 'image/jpeg', 'object_path': 'private', 'media_expires_at': now.add(const Duration(hours: 1)).toIso8601String()}
      ]}];
      await first.save();
      now = now.add(const Duration(hours: 2));
      final second = EncryptedCache('owner', secrets, directory: root, clock: () => now);
      await second.initialize();
      expect(second.data['messages.self'][0]['body'], 'Keep text');
      expect(second.data['messages.self'][0]['message_attachments'], isEmpty);
    } finally { await root.delete(recursive: true); }
  });
  test('managed downloaded video is removed at its deadline', () async {
    final root = await Directory.systemTemp.createTemp('media-retention-files');
    try {
      final files = PrivateMediaFiles(root: root);
      final file = await files.video(Uint8List.fromList([1, 2]), expiresAt: DateTime.now().add(const Duration(milliseconds: 20)));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(await file.exists(), isFalse);
    } finally { await root.delete(recursive: true); }
  });
}
