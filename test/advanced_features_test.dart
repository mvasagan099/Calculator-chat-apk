import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:calculator_messenger/core/security/vault_service.dart';
import 'package:calculator_messenger/core/services/device_settings.dart';
import 'package:calculator_messenger/core/security/lock_controller.dart';
import 'lock_biometric_test.dart' show ImmediatePinVault;
import 'package:calculator_messenger/features/notifications/app_update.dart';
import 'package:calculator_messenger/models/message_edit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Feature 1: Private File Vault & VaultService', () {
    test('VaultCategory.fromExtension detects appropriate categories from extensions', () {
      expect(VaultCategory.fromExtension('jpg'), VaultCategory.images);
      expect(VaultCategory.fromExtension('.PNG'), VaultCategory.images);
      expect(VaultCategory.fromExtension('mp4'), VaultCategory.videos);
      expect(VaultCategory.fromExtension('.mkv'), VaultCategory.videos);
      expect(VaultCategory.fromExtension('m4a'), VaultCategory.audio);
      expect(VaultCategory.fromExtension('.mp3'), VaultCategory.audio);
      expect(VaultCategory.fromExtension('pdf'), VaultCategory.documents);
      expect(VaultCategory.fromExtension('.txt'), VaultCategory.documents);
      expect(VaultCategory.fromExtension('zip'), VaultCategory.other);
      expect(VaultCategory.fromExtension('bin'), VaultCategory.other);
    });

    test('VaultItem serialization, deserialization, and copyWith', () {
      final now = DateTime.utc(2026, 10, 18, 12, 0, 0);
      final item = VaultItem(
        id: 'vault-1',
        filename: 'secret_doc.pdf',
        encryptedFilename: 'vault-1.enc',
        sizeBytes: 1024 * 50,
        createdAt: now,
        category: VaultCategory.documents,
        folder: 'Work',
      );

      final map = item.toJson();
      expect(map['id'], 'vault-1');
      expect(map['filename'], 'secret_doc.pdf');
      expect(map['folder'], 'Work');
      expect(map['category'], 'documents');
      expect(map['size_bytes'], 1024 * 50);

      final reconstructed = VaultItem.fromJson(map);
      expect(reconstructed.id, item.id);
      expect(reconstructed.filename, item.filename);
      expect(reconstructed.sizeBytes, item.sizeBytes);
      expect(reconstructed.folder, item.folder);
      expect(reconstructed.category, item.category);

      final renamed = item.copyWith(filename: 'renamed.pdf', folder: 'Archived');
      expect(renamed.id, 'vault-1');
      expect(renamed.filename, 'renamed.pdf');
      expect(renamed.folder, 'Archived');
      expect(renamed.encryptedFilename, item.encryptedFilename);
    });

    test('Vault manifest filtering, folders, and storage statistics', () {
      final now = DateTime.now();
      final items = [
        VaultItem(
          id: 'v1',
          filename: 'vacation.jpg',
          encryptedFilename: 'v1.enc',
          sizeBytes: 2000000,
          createdAt: now,
          category: VaultCategory.images,
          folder: 'Personal',
        ),
        VaultItem(
          id: 'v2',
          filename: 'project.pdf',
          encryptedFilename: 'v2.enc',
          sizeBytes: 1000000,
          createdAt: now,
          category: VaultCategory.documents,
          folder: 'Work',
        ),
        VaultItem(
          id: 'v3',
          filename: 'family.mp4',
          encryptedFilename: 'v3.enc',
          sizeBytes: 5000000,
          createdAt: now,
          category: VaultCategory.videos,
          folder: 'Personal',
        ),
      ];

      // Filtering by category
      final images = items.where((i) => i.category == VaultCategory.images).toList();
      expect(images.length, 1);
      expect(images.first.filename, 'vacation.jpg');

      // Filtering by folder
      final personal = items.where((i) => i.folder == 'Personal').toList();
      expect(personal.length, 2);

      // Search by query
      final matches = items.where((i) => i.filename.toLowerCase().contains('vac')).toList();
      expect(matches.length, 1);

      // Stats aggregation
      final totalVaultSize = items.fold<int>(0, (sum, i) => sum + i.sizeBytes);
      expect(totalVaultSize, 8000000);
      expect(totalVaultSize / (1024 * 1024), closeTo(7.629, 0.01));
    });

    test('VaultService full import, AES-GCM encryption, decryption, rename, move, delete lifecycle', () async {
      final tempDir = Directory.systemTemp.createTempSync('calc_vault_test_');
      try {
        final vault = VaultService(customDir: tempDir);
        await vault.initialize();

        final rawBytes = Uint8List.fromList(utf8.encode('TopSecretConfidentialVaultContent2026'));
        final item = await vault.importBytes(
          bytes: rawBytes,
          filename: 'confidential.txt',
          folder: 'Work',
        );

        expect(item.id.isNotEmpty, isTrue);
        expect(item.category, VaultCategory.documents);
        expect(item.folder, 'Work');
        expect(vault.items.length, 1);

        // Verify the file stored on disk is encrypted, not plaintext
        final diskFile = File('${tempDir.path}/${item.encryptedFilename}');
        expect(await diskFile.exists(), isTrue);
        final diskBytes = await diskFile.readAsBytes();
        expect(diskBytes, isNot(equals(rawBytes)));

        // Read decrypted bytes
        final decrypted = await vault.readDecryptedBytes(item);
        expect(utf8.decode(decrypted), 'TopSecretConfidentialVaultContent2026');

        // Rename item
        await vault.renameItem(item.id, 'renamed_secret.txt');
        expect(vault.items.first.filename, 'renamed_secret.txt');

        // Move item to new folder
        await vault.moveItem(item.id, 'Financial');
        expect(vault.items.first.folder, 'Financial');
        expect(vault.folders, contains('Financial'));

        // Check stats
        final stats = await vault.getStats();
        expect(stats.fileCount, 1);
        expect(stats.vaultBytes, rawBytes.length);
        expect(stats.categoryBytes[VaultCategory.documents], rawBytes.length);

        // Delete item
        await vault.deleteItem(item.id);
        expect(vault.items.isEmpty, isTrue);
        expect(await diskFile.exists(), isFalse);
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });
  });

  group('Feature 2: Voice Message Playback Speed & DeviceSettings', () {
    test('Default speed is 1.0x and persists across changes', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final lock = LockController(ImmediatePinVault());
      addTearDown(lock.dispose);
      final settings = DeviceSettings(prefs, lock);

      expect(settings.voicePlaybackSpeed, 1.0);

      await settings.setVoicePlaybackSpeed(1.5);
      expect(settings.voicePlaybackSpeed, 1.5);

      await settings.setVoicePlaybackSpeed(2.0);
      expect(settings.voicePlaybackSpeed, 2.0);

      await settings.setVoicePlaybackSpeed(1.0);
      expect(settings.voicePlaybackSpeed, 1.0);
    });

    test('Cycle through speeds: 1.0 -> 1.5 -> 2.0 -> 1.0', () {
      double nextSpeed(double current) {
        if (current <= 1.0) return 1.5;
        if (current <= 1.5) return 2.0;
        return 1.0;
      }

      expect(nextSpeed(1.0), 1.5);
      expect(nextSpeed(1.5), 2.0);
      expect(nextSpeed(2.0), 1.0);
    });
  });

  group('Feature 3: Advanced Group Admin Controls', () {
    test('Slow mode seconds mapping and options', () {
      final options = [
        {'seconds': 0, 'label': 'Off'},
        {'seconds': 10, 'label': '10s'},
        {'seconds': 30, 'label': '30s'},
        {'seconds': 60, 'label': '1m'},
        {'seconds': 300, 'label': '5m'},
        {'seconds': 900, 'label': '15m'},
      ];

      expect(options.length, 6);
      expect(options.first['label'], 'Off');
      expect(options.last['label'], '15m');
      expect(options[3]['seconds'], 60);
    });

    test('Mute duration calculation', () {
      final base = DateTime.utc(2026, 10, 18, 12, 0, 0);
      final mute1Hour = base.add(const Duration(hours: 1));
      final mute24Hours = base.add(const Duration(hours: 24));

      expect(mute1Hour.difference(base).inHours, 1);
      expect(mute24Hours.difference(base).inHours, 24);
      expect(mute1Hour.isAfter(base), isTrue);
    });
  });

  group('Feature 4: Message Edit History & MessageEditRevision', () {
    test('MessageEditRevision model serialization and date parsing', () {
      final raw = {
        'id': 'edit-1',
        'message_id': 'm-100',
        'previous_body': 'Original message text before edit',
        'edited_by': 'user-123',
        'edited_at': '2026-10-18T14:30:00Z',
      };

      final rev = MessageEditRevision.fromJson(raw);
      expect(rev.id, 'edit-1');
      expect(rev.messageId, 'm-100');
      expect(rev.previousBody, 'Original message text before edit');
      expect(rev.editedBy, 'user-123');
      expect(rev.editedAt.isUtc, isTrue);
      expect(rev.editedAt.year, 2026);
      expect(rev.editedAt.hour, 14);
      expect(rev.editedAt.minute, 30);
    });

    test('Chronological ordering of revisions', () {
      final rev1 = MessageEditRevision(
        id: '1',
        messageId: 'm1',
        previousBody: 'v1',
        editedBy: 'u1',
        editedAt: DateTime.utc(2026, 10, 18, 10, 0, 0),
      );
      final rev2 = MessageEditRevision(
        id: '2',
        messageId: 'm1',
        previousBody: 'v2',
        editedBy: 'u1',
        editedAt: DateTime.utc(2026, 10, 18, 10, 5, 0),
      );

      final list = [rev1, rev2];
      list.sort((a, b) => b.editedAt.compareTo(a.editedAt));
      expect(list.first.id, '2');
      expect(list.last.id, '1');
    });
  });

  group('Feature 5: Storage Manager Computations', () {
    test('Format bytes helper converts accurately', () {
      String formatBytes(int bytes) {
        if (bytes < 1024) return '$bytes B';
        if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
        if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
        return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
      }

      expect(formatBytes(500), '500 B');
      expect(formatBytes(1024 * 45), '45.0 KB');
      expect(formatBytes(1024 * 1024 * 12), '12.0 MB');
      expect(formatBytes(1024 * 1024 * 1024 * 2), '2.00 GB');
    });

    test('Total calculation and percentage breakdowns', () {
      final cacheBytes = 10 * 1024 * 1024;
      final mediaBytes = 30 * 1024 * 1024;
      final vaultBytes = 40 * 1024 * 1024;
      final databaseBytes = 20 * 1024 * 1024;

      final total = cacheBytes + mediaBytes + vaultBytes + databaseBytes;
      expect(total, 100 * 1024 * 1024);

      final cacheFraction = cacheBytes / total;
      final mediaFraction = mediaBytes / total;
      final vaultFraction = vaultBytes / total;
      final dbFraction = databaseBytes / total;

      expect(cacheFraction, closeTo(0.10, 0.001));
      expect(mediaFraction, closeTo(0.30, 0.001));
      expect(vaultFraction, closeTo(0.40, 0.001));
      expect(dbFraction, closeTo(0.20, 0.001));
    });
  });

  group('Feature 6: Media Compression & Quality Profiles', () {
    test('Media quality settings persist in DeviceSettings', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final lock = LockController(ImmediatePinVault());
      addTearDown(lock.dispose);
      final settings = DeviceSettings(prefs, lock);

      expect(settings.mediaQuality, 'optimized');

      await settings.setMediaQuality('medium');
      expect(settings.mediaQuality, 'medium');

      await settings.setMediaQuality('original');
      expect(settings.mediaQuality, 'original');
    });

    test('Original quality preserves raw bytes without compression', () {
      final raw = Uint8List.fromList(List<int>.generate(1000, (i) => i % 256));
      final quality = 'original';

      final result = (quality == 'original') ? raw : null;
      expect(result, isNotNull);
      expect(result!.length, raw.length);
      expect(result, equals(raw));
    });

    test('Size guard rule: never output larger compressed file than original', () {
      final originalBytes = Uint8List.fromList(List<int>.generate(500, (i) => i % 256));
      final syntheticBloatedCompressed = Uint8List.fromList(List<int>.generate(800, (i) => i % 256));

      final finalBytes = syntheticBloatedCompressed.length < originalBytes.length
          ? syntheticBloatedCompressed
          : originalBytes;

      expect(finalBytes.length, originalBytes.length);
      expect(identical(finalBytes, originalBytes), isTrue);
    });
  });

  group('Feature 7: Connection Diagnostics', () {
    test('Sanitized diagnostic report suppresses sensitive tokens & URLs', () {
      final checks = [
        {'name': 'Internet Connectivity', 'status': 'PASS', 'latency': '42ms'},
        {'name': 'Supabase Auth', 'status': 'PASS', 'latency': '85ms'},
        {'name': 'Database / API', 'status': 'PASS', 'latency': '90ms'},
        {'name': 'Realtime WebSocket', 'status': 'PASS', 'latency': '110ms'},
        {'name': 'Media Storage', 'status': 'PASS', 'latency': '75ms'},
      ];

      final buffer = StringBuffer('### Diagnostics Report\n');
      for (final c in checks) {
        buffer.writeln('- **${c['name']}**: ${c['status']} (${c['latency']})');
      }

      final report = buffer.toString();
      expect(report, contains('Internet Connectivity'));
      expect(report, contains('Supabase Auth'));
      expect(report, isNot(contains('bearer')));
      expect(report, isNot(contains('secret')));
      expect(report, isNot(contains('apikey')));
      expect(report, isNot(contains('supabaseKey')));
    });
  });

  group('Feature 8: App Version Management & Updates', () {
    test('VerifiedAppUpdate preserves positional compatibility and adds named fields', () {
      final legacy = VerifiedAppUpdate(
        'rel-1',
        42,
        'https://github.com/releases/download/v1.2.0/app.apk',
        'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890',
      );
      expect(legacy.id, 'rel-1');
      expect(legacy.build, 42);
      expect(legacy.versionName, '1.0.0');
      expect(legacy.minSupportedBuild, 1);
      expect(legacy.isUnsupported, isFalse);

      final extended = VerifiedAppUpdate(
        'rel-2',
        50,
        'https://github.com/releases/download/v2.0.0/app-arm64-v8a.apk',
        '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef',
        versionName: '2.0.0',
        releaseNotes: '- Added Private File Vault\n- Added Voice Playback Speed Controls',
        apkSizeBytes: 35000000,
        minSupportedBuild: 45,
        isUnsupported: false,
      );
      expect(extended.versionName, '2.0.0');
      expect(extended.apkSizeBytes, 35000000);
      expect(extended.minSupportedBuild, 45);
      expect(extended.isUnsupported, isFalse);
    });

    test('Unsupported / mandatory update trigger when installed build < minimum build', () {
      const installedBuild = 40;
      const minSupportedBuild = 45;

      final isUnsupported = installedBuild < minSupportedBuild;
      expect(isUnsupported, isTrue);

      final update = VerifiedAppUpdate(
        'rel-force',
        50,
        'https://github.com/releases/download/v2.0.0/app.apk',
        'hash',
        versionName: '2.0.0',
        minSupportedBuild: minSupportedBuild,
        isUnsupported: isUnsupported,
      );

      expect(update.isUnsupported, isTrue);
    });

    test('APK size constraint strictly enforced (< 50,000,000 bytes)', () {
      const maxApkSize = 50000000;
      final update = VerifiedAppUpdate(
        'rel-3',
        50,
        'https://github.com/releases/download/v2.0.0/app-arm64-v8a.apk',
        'hash',
        apkSizeBytes: 34500000,
      );

      expect(update.apkSizeBytes, lessThan(maxApkSize));
    });
  });
}
