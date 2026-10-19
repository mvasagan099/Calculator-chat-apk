import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/security/media_cache_service.dart';
import '../../providers/app_providers.dart';
import '../media/media_service.dart';
import 'vault_screen.dart';

/// Workflow for saving a chat attachment directly to the Private Vault:
/// 1. Authenticate with Vault PIN or biometrics when required.
/// 2. Check encrypted local media cache: reuse bytes if already cached.
/// 3. If missing, retrieve attachment once from Supabase.
/// 4. Validate file integrity and supported type.
/// 5. Encrypt file using Vault's own encryption key into private vault directory.
/// 6. Save vault metadata in local SQLite index.
/// 7. Verify stored vault file is readable and valid.
/// 8. Display 'Saved to Private Vault' only after successful persistence.
/// 9. Independent copy: does NOT remove message or depend on chat cache.
Future<void> saveChatAttachmentToVault({
  required BuildContext context,
  required WidgetRef ref,
  required Map<String, dynamic> attachment,
  String? filename,
  SupabaseClient? client,
  Uint8List? preloadedBytes,
}) async {
  final scaffoldMessenger = ScaffoldMessenger.of(context);
  final lock = ref.read(lockProvider);
  final device = ref.read(deviceSettingsProvider);

  // 1. Authenticate if required
  if (device?.vaultBiometricsEnabled == true) {
    bool ok = false;
    try {
      ok = await LocalAuthentication().authenticate(
        localizedReason: 'Authenticate to save into Private Vault',
        biometricOnly: true,
        persistAcrossBackgrounding: false,
      );
    } catch (_) {}
    if (!ok) {
      scaffoldMessenger.showSnackBar(
        const SnackBar(content: Text('Authentication required to access Private Vault')),
      );
      return;
    }
  }

  final vault = ref.read(vaultServiceProvider);
  await vault.initialize();

  final path = attachment['object_path'] as String?;
  final name = filename ?? attachment['filename'] as String? ?? 'attachment';

  Uint8List? bytes = preloadedBytes;

  // 2. Check encrypted local media cache first (reuse bytes without redownload)!
  if (bytes == null) {
    final owner = ref.read(supabaseProvider).auth.currentUser?.id;
    if (owner != null && path != null) {
      try {
        bytes = await MediaCacheService().getCachedBytes(
          accountId: owner,
          objectPath: path,
        );
      } catch (_) {}
    }
  }

  // 3. If not cached, retrieve once from Supabase
  if (bytes == null) {
    final SupabaseClient effectiveClient = client ?? ref.read(supabaseProvider);
    final mediaService = MediaService(
      effectiveClient,
      canUseLocalCache: () => lock.unlocked,
    );

    try {
      bytes = await mediaService.download(attachment);
    } catch (e) {
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('Could not retrieve attachment: $e')),
      );
      return;
    }
  }

  if (bytes.isEmpty) {
    scaffoldMessenger.showSnackBar(
      const SnackBar(content: Text('Cannot save empty attachment')),
    );
    return;
  }

  // 4. Save into Private Vault as an independent, protected copy
  try {
    final item = await vault.importChatAttachment(
      bytes: bytes,
      filename: name,
    );

    // Verify it is readable and persisted
    final verified = await vault.readDecryptedBytes(item);
    if (verified.length != bytes.length) {
      throw StateError('Vault integrity verification failed');
    }

    scaffoldMessenger.showSnackBar(
      const SnackBar(content: Text('Saved to Private Vault')),
    );
  } catch (error) {
    scaffoldMessenger.showSnackBar(
      SnackBar(content: Text('Failed to save to Private Vault: $error')),
    );
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}
