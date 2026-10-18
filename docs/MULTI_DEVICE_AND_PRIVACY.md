# Multi-Device Synchronization, Encrypted Backup, & Advanced Privacy

This document outlines the architecture, implementation, and verification for three core capabilities in Calculator Messenger:
1. **Multi-device Login, Synchronization, and Revocation**
2. **Encrypted Backup and Restore (Zero Data Loss)**
3. **Advanced Privacy and Calling Features (Quick Privacy Lock, Private Notification Controls, PiP Video Calls, & Android Telecom VoIP Integration)**

---

## 1. Multi-Device Login, Synchronization, and Revocation

### Architecture & Data Flow
Multi-device support enables users to pair multiple phones or desktop clients while retaining end-to-end security and device authorization control.

```
+-------------------+        Supabase Realtime         +-------------------+
|  Approved Device  | <------------------------------> |  New / Pending    |
|   (e.g., Phone)   |    channel: 'account_devices'    |   Device (e.g. PC)|
+-------------------+                                  +-------------------+
          |                                                      |
          | Approve / Revoke                                     | Polling Fallback
          v                                                      v
  [public.account_devices] <--------------------------- [DeviceApprovalScreen]
          |
          +--> Event: Approved -> Unlocks UI & syncs history
          +--> Event: Revoked  -> Immediate lock & session teardown
```

### Key Implementation Details
1. **Realtime Device Publication & RPC**:
   - Migration [`supabase/migrations/202610180017_multidevice_sync.sql`](file:///c:/Users/Devan/Downloads/chatapp/supabase/migrations/202610180017_multidevice_sync.sql) adds `public.account_devices` to `supabase_realtime` publication.
   - Provides `rename_account_device(target_device_id, new_device_name)` RPC with caller ownership verification.
2. **Realtime Auth Listener**:
   - [`AuthService._subscribeDeviceRealtime`](file:///c:/Users/Devan/Downloads/chatapp/lib/core/services/auth_service.dart) subscribes to `postgres_changes` on `account_devices`.
   - On `UPDATE` or `DELETE`, it evaluates the current device's status (`approved`, `revoked`, or `pending`).
   - If revoked, the app locks immediately and revokes local credential cache.
   - If approved, waiting screens transition automatically without requiring app restart.
3. **Conversations & Read Receipts Sync**:
   - [`MessengerRepository.sync()`](file:///c:/Users/Devan/Downloads/chatapp/lib/repositories/messenger_repository.dart) fetches latest unread counters and invokes `ack_messages` across connected devices.
   - [`ChatListScreen`](file:///c:/Users/Devan/Downloads/chatapp/lib/features/chats/chat_list_screen.dart) incorporates pull-to-refresh (`RefreshIndicator`) to sync read receipts and conversations on demand.
4. **Device Management UI**:
   - [`DeviceSessionsScreen`](file:///c:/Users/Devan/Downloads/chatapp/lib/features/devices/device_screens.dart) displays active devices with status chips ("Current", "Approved", "Pending", "Revoked"), device renaming, individual device revocation, and "Revoke other sessions" actions.

---

## 2. Encrypted Backup and Restore (Zero Data Loss)

### Security Specification
- **Key Derivation Function (KDF)**: PBKDF2-HMAC-SHA256 with 100,000 iterations and a cryptographically secure 16-byte random salt.
- **Authenticated Encryption**: AES-256-GCM with a unique 12-byte nonce per backup and Authenticated Additional Data (`aad = 'backup:v1:<user_id>'`).
- **Cryptographic File Structure**:
  ```json
  {
    "format": "calculator_messenger_backup",
    "version": 1,
    "user_id": "<uuid>",
    "created_at": "2026-10-18T12:00:00.000Z",
    "kdf": {
      "algorithm": "PBKDF2-HMAC-SHA256",
      "iterations": 100000,
      "salt": "<base64>"
    },
    "cipher": {
      "algorithm": "AES-256-GCM",
      "nonce": "<base64>",
      "tag": "<base64>",
      "ciphertext": "<base64>"
    },
    "summary": {
      "conversations": 12,
      "messages": 350
    }
  }
  ```

### Outbox Preservation & Deduplication Guarantee
- **Zero Accidental Data Loss Rule**: When restoring a backup, existing offline outbox messages in `cache.data['outbox']` are captured before merging:
  ```dart
  final existingOutbox = cache.data['outbox'];
  // ... merge conversations & messages ...
  if (existingOutbox != null) {
    cache.data['outbox'] = existingOutbox;
  }
  ```
  Pending outbox items are never overwritten or deleted by incoming backups.
- **Message Deduplication & Retention**: Historical messages are merged by unique message `id`, sorted newest-first, and pruned for expiration timers via `pruneLocalData`.

---

## 3. Advanced Privacy & Calling Features

### Quick Privacy Lock
- **Shake to Lock**:
  - Implemented in Kotlin via `SensorEventListener` on the accelerometer in [`MainActivity.kt`](file:///c:/Users/Devan/Downloads/chatapp/android/app/src/main/kotlin/app/calculatorspace/calculator_messenger/MainActivity.kt).
  - Triggers when acceleration exceeds $2.5g$. Dispatches `privacyChannel.invokeMethod("quickLock", null)` to Flutter.
  - Can be toggled on/off in Settings via `DeviceSettings.setShakeToLock(bool)`.
- **Keyboard & Hotkey Shortcuts**:
  - Configured in [`PrivateScaffold`](file:///c:/Users/Devan/Downloads/chatapp/lib/core/widgets/private_scaffold.dart) with `CallbackShortcuts`:
    - `LogicalKeyboardKey.escape`: Quick return to calculator.
    - `Ctrl + Alt + L`: Configurable desktop/physical keyboard lock shortcut.
- **Relock Teardown**:
  - `LockController.quickLock()` clears active PIN buffers, cancels pending unlock operations, and triggers `onRelock` callback to teardown active media viewers, video calls, or floating windows.

### Private Notification Controls
Configurable in Settings under `NotificationPrivacy`:
1. `NotificationPrivacy.detailed`:
   - Reveals sender names in messages and incoming calls (e.g. *"Incoming call from Alice"*, *"Alice: New message"*).
   - Routes to audible and high-priority notification channels (`incoming_calls`, `activity`, `missed_calls`).
2. `NotificationPrivacy.generic` (Default):
   - Masks sender identity and message content behind disguise text (*"New activity"*, *"Calculator Notification"*).
   - Prevents shoulder-surfing and lock screen data exposure.
3. `NotificationPrivacy.silent`:
   - Suppresses ringtones, sounds, and vibrations.
   - Routes to low-importance channels (`silent_calls`, `silent_activity`).

### Picture-in-Picture (PiP) Video Calls
- **Floating Video Window**:
  - Android 8.0+ `enterPictureInPictureMode` configured in `AndroidManifest.xml` (`android:supportsPictureInPicture="true"`).
  - Managed by `CallController.enterPip()` and `CallController.closePip()`.
  - When in PiP mode, `CallScreen` presents a full-bleed floating participant grid.
- **Strict Relock Privacy Guard**:
  - When the app is locked or returns to the calculator screen, `CallController.handleRelock()` runs automatically:
    ```dart
    if (inPip) await closePip();
    if (camera) {
      camera = false;
      await transport.camera(false);
    }
    ```
  - This ensures no live video feed or participant image remains visible outside the unlocked messenger.

### Android Telecom ConnectionService Integration
- **Self-Managed VoIP**:
  - [`TelecomConnectionService.kt`](file:///c:/Users/Devan/Downloads/chatapp/android/app/src/main/kotlin/app/calculatorspace/calculator_messenger/TelecomConnectionService.kt) implements Android Telecom `ConnectionService` with `PhoneAccount.CAPABILITY_SELF_MANAGED`.
  - Integrates with Android system audio routing (speakerphone, earpiece, Bluetooth headsets, CarAudio).
- **System Call Actions**:
  - Native answer/reject actions forward `telecomAnswer` and `telecomReject` calls to Flutter via `AndroidCallDevice.channel`.
  - [`CallController`](file:///c:/Users/Devan/Downloads/chatapp/lib/features/calls/call_controller.dart) accepts or rejects the call in LiveKit/Supabase.
- **Missed Call Tracking**:
  - When an incoming call transitions from `ringing` to `cancelled`, `timeout`, or `missed`, `CallController.onMissedCall` is triggered, displaying a missed-call notification adhering to the user's `NotificationPrivacy` settings.

---

## 4. Verification Suite

All features are tested by dedicated unit and widget test suites in `test/`:
- [`test/backup_restore_test.dart`](file:///c:/Users/Devan/Downloads/chatapp/test/backup_restore_test.dart): Tests PBKDF2/AES-GCM encryption, decryption, invalid password rejection, tampering resistance, message deduplication, and outbox queue preservation.
- [`test/quick_privacy_lock_test.dart`](file:///c:/Users/Devan/Downloads/chatapp/test/quick_privacy_lock_test.dart): Tests `quickLock()`, shake-to-lock toggle, `onRelock` callback execution, and `Escape`/`Ctrl+Alt+L` keyboard shortcuts.
- [`test/notification_privacy_test.dart`](file:///c:/Users/Devan/Downloads/chatapp/test/notification_privacy_test.dart): Tests `generic`, `detailed`, and `silent` notification behaviors for incoming calls and missed calls.
- [`test/call_pip_telecom_test.dart`](file:///c:/Users/Devan/Downloads/chatapp/test/call_pip_telecom_test.dart): Tests PiP lifecycle, relock privacy enforcement (closing PiP and muting camera), Telecom connection triggers, and missed-call notifications.
- Local syntax scanner verified 100% clean across all 23 modified/new files.
