# Real data, encrypted SQLite and performance

The connected application now uses **Supabase for shared data and transactional SQLite for private offline history/outbox**. It does not turn preview fixtures into real conversations. The owner-supplied project URL/public publishable key were saved in ignored configuration, not source. Local configuration validation passes; live provider validation still fails at this cloud proxy with CONNECT HTTP 403. No remote database migration, function deployment or account creation was performed.

## Appropriate storage roles

| Data | Storage and access |
| --- | --- |
| Accounts, profiles, conversations, durable messages, receipts, group/call/status state | Existing Supabase Auth/PostgreSQL/RLS and authenticated RPCs/Realtime |
| Recent authenticated chat windows, conversation list, pending messages, wallpapers/expiry preferences | New app-private SQLite cache with AES-256-GCM encrypted collections |
| PIN verifier/throttle, account session/refresh credentials, local master key | Existing Android Keystore-backed secure storage; never SQLite plaintext |
| Attachments | Private Supabase Storage with membership checks/server validation; app-private managed temporary files for playback/viewing |
| Local preview | Clearly marked fixtures, isolated from connected credentials/PIN/cache; no simulated backend writes |

SQLite does **not** synchronize accounts/devices or replace deployed RLS and backend functions. Supabase remains authoritative for permissions, chronology, delivery/read receipts and history. Media binaries are not added as giant SQLite blobs or copied into a public gallery. Existing keyset history queries and 200-message/20-chat message-cache bounds remain.

The production repository now creates `SqliteEncryptedCache` through a small `LocalCache` interface. The old encrypted file implementation remains for compatibility fixtures/benchmark comparison. Initialization is shared by concurrent callers; replacing an account closes the previous cache and releases its plaintext references. Relock/dispose drains pending local writes, closes SQLite and releases keys/cache snapshots. Logout/explicit local-clear removes database/WAL files, legacy files and that account's cache key. None of these paths reset a calculator PIN.

## SQLite schema and protection

Runtime local schema version 1 contains `cache_entries` (opaque indexed primary key, nonce, ciphertext, tag) and a small migration metadata table. Each bounded message window/conversation list/outbox/settings collection is authenticated and encrypted before SQLite receives it. Identity labels use HMAC-SHA256 with a separate HKDF-derived indexing key; AES-GCM additional authenticated data binds the account, format and row identity. An encrypted root manifest rejects incomplete/swapped collections. Keys are random device-local material kept through the existing secure-store key name, not a weak numeric PIN-derived database password.

This is **application-level payload encryption, not SQLCipher/full-file encryption**. SQLite headers, file sizes, row counts, write patterns, migration state and the account identifier in the private filename remain visible to an attacker with filesystem access. It is not application E2EE: Supabase infrastructure can still read server messages/media. No plaintext message search/FTS index is created. Existing authenticated server search/in-memory loaded-window search are preserved.

Transactions use parameterized inserts/deletes, WAL, FULL synchronization and secure-delete configuration. No message text becomes SQL syntax. Encryption/decryption and legacy decoding run in a Dart worker; sqflite executes Android database work off its UI thread. JSON snapshot creation/retention still run on the main isolate and the bounded cached collections remain resident while unlocked; this is not a measured Android memory/frame-time guarantee or lazy per-message SQL pagination implementation.

## Migration and failure safety

- Existing `cache-USER.bin` files use the same retained Keystore-backed master key. Read/verify the old AEAD format, apply existing expiration/view-once rules, transactionally write SQLite collections plus migration marker, then decrypt/read back before removing the old file.
- Pending UUIDs, queue state and settings are preserved. A crash-leftover exact imported file is identified by its ciphertext digest and removed without replaying old pending messages.
- A **changed** legacy file after an app downgrade is preserved and causes a recoverable cache error instead of silently deleting its newer outbox or merging stale data. Review/recover the two copies with owner consent; do not uninstall, clear app data or blindly delete either file.
- Missing keys, corrupt legacy files, modified ciphertext, incomplete collection manifests and inconsistent migration metadata fail closed. The loader does not rotate the key, recreate the database or wipe an unreadable outbox. Explicit recovery/local clearing requires the existing owner-authorized settings flow.
- Failed SQLite transactions retain the prior durable snapshot. Relocking releases in-memory data and key references after queued writes; this is not a guarantee of forensic erasure from RAM, flash, backups or previously authorized external copies.

## Performance changes and evidence

Only changed collections are encrypted/upserted. Unchanged data returns without an SQL write transaction; changing one cached chat leaves the other ciphertext rows byte-for-byte unchanged. A chat edit rewrites its bounded encrypted collection, not every message in every chat. Expiry checks preserve unchanged row/list identities and skip unnecessary saves/stream notifications. Outbox mutations and RPC completion handling revalidate their originating account/cache/session epoch so old callbacks cannot write a replacement account's database.

A three-sample synthetic **desktop Flutter JIT benchmark**, using real files and OS SQLite plus an in-memory key-store adapter, with 20 chats × 200 messages:

| Operation | Encrypted JSON file | Encrypted SQLite collections |
| --- | ---: | ---: |
| Single-chat update, median | 224.549 ms | 23.132 ms |
| Unchanged save, median | 226.740 ms | 8.776 ms |
| Restore, single observation | 509.413 ms | 208.263 ms |

[Raw durations](sqlite-performance-desktop.json). These measure storage-path wall time on this host, not actual Android Keystore, network, render latency, startup or battery life. File-store comparison includes its existing restore-time rewrite. SQL crypto runs in a worker and actual Android sqflite scheduling differs from this host engine. No phone speedup is claimed until measured there.

The Android app uses maintained `sqflite` 2.4.4+2/platform SQLite. Desktop tests deliberately use FFI 2.3.7+1 with the SQLite 2.x OS loader: the initially evaluated FFI 2.4/native-assets driver staged an unused second SQLite engine for Android even though it was test-only. The compatible test-only constraint avoids that payload; the Linux harness supports both the development library name and runtime `.so.0`. Existing application dependency versions were not upgraded. Generated build outputs were cleaned to retire obsolete staged binaries; no installed app data was touched.

Run the explicit benchmark separately from ordinary regressions:

```sh
./scripts/flutterw test tool/cache_benchmark_test.dart --reporter expanded
```

## Current service/configuration status

Project reference: `vjjvfshpzihbrdakbzct`; origin: `https://vjjvfshpzihbrdakbzct.supabase.co`. The supplied `sb_publishable_...` value is a public client key, accepted under the legacy configuration name `SUPABASE_ANON_KEY`; it is never a service-role key.

Ignored `config/connected-public.json` holds the supplied public pair and `LOCAL_UI_PREVIEW=false`. The existing preview `config/local.json` is preserved. The validated build file is `config/connected-build.json`; no Firebase console JSON is present locally, so local preparation explicitly reports Google Services disabled. The owner-reported raw Firebase GitHub secret remains the CI path for FCM client configuration.

```sh
python3 scripts/prepare-client-config.py --mode connected \
  --input config/connected-public.json --output config/connected-build.json
./scripts/flutterw build apk --debug \
  --dart-define-from-file=config/connected-build.json
```

For FCM locally, add the owner's console file at `android/app/google-services.json` and pass `--firebase-android android/app/google-services.json`. Never add a Firebase service account, Supabase service role, LiveKit secret, account password or signing key to build configuration.

The public key/URL match is **not provider-verified**: read-only Auth settings were blocked by proxy CONNECT 403 before reaching Supabase. The public key cannot inspect/apply privileged schema migrations. Authorized management/database access or owner-run `supabase/remote_preflight.sql` plus migration history is still needed. Review the exact target and pending changes, obtain explicit owner migration confirmation, then coordinate the existing 11 migrations/nine Edge Functions and reviewed worker settings. No new remote SQL migration is required for local SQLite.

GitHub API requests to set the repository URL variable and dispatch Actions returned Forbidden. The public pair was saved as suggestions in the cloud environment draft; that did not apply runtime variables, publish an environment, set GitHub variables or deploy services. Configure repository variables `SUPABASE_URL`/`SUPABASE_ANON_KEY` with the supplied public values and run `Android debug APK` on `codex/phase2-apk-verification`, mode `connected`. Expected artifact: `calculator-messenger-debug-connected`; no new connected artifact/hash is claimed.

Actual registration/login, two-account realtime chat, media transfer, FCM delivery and LiveKit media still require deployed services and disposable accounts/devices from HOSTED_TESTS.md and DEVICE_ACCEPTANCE.md. The previously reported working preview installation is separate evidence. Do not uninstall or clear it to bypass a debug-signing mismatch.

## Validation for this change

Analysis and locked dependency resolution passed. The Flutter suite passed 111 tests with one hosted test skipped; Python tooling passed 37 tests, local PostgreSQL passed eight suites and two concurrency checks, and Edge Function security tests passed seven tests. Edge type checks and workflow lint passed. SQLite tests execute real desktop SQLite; messaging HTTP adapters and secure-store test adapters are explicitly simulated, so these results do not verify a deployed backend or Android Keystore.

`integration_test/sqlite_storage_test.dart` provides an Android SQLite/secure-store round trip using a unique test namespace and fresh temporary directory. It is **NOT RUN**. Run only on an owner-approved disposable Android device/profile:

```sh
./scripts/flutterw test integration_test/sqlite_storage_test.dart -d DEVICE_ID
```

Flutter may reinstall the application during integration testing. Do not run this against the existing preview installation without owner approval and a safe data/signing plan. The test never reads or resets an existing account/PIN, but tooling installation behavior is outside its namespace isolation.

The connected debug build was attempted and failed resolving official Flutter engine artifacts with HTTP 403; no new APK or checksum exists. The existing debug workflow is preserved. GitHub Actions dispatch remains blocked by API access; the owner can start the connected build after verifying repository variables.
