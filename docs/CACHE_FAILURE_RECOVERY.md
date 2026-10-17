# Android encrypted cache failure — safe online recovery

Observed owner report: “Encrypted local cache is unavailable; existing files were preserved” and “Could not load. Check your connection.” The former is thrown during `SqliteEncryptedCache.initialize` and then propagated through `MessengerRepository.prepare`, blocking all conversation reads and sends. The latter is a generic widget error that does **not** prove network failure. Supabase had successful conversation-list/message GETs, two conversation rows and zero server messages when checked. The exact Android key/SQLite failure still needs a device diagnostic.

## What this patch does
- When encrypted cache initialization fails, **never** delete, overwrite, recreate its key or reinitialize the encrypted SQLite/binary files. `SqliteEncryptedCache` still preserves the original ciphertext.
- Start an explicitly labeled **volatile, online-only** repository instance. Chats are fetched from server; memory-only copies disappear when session ends. No plaintext files/cache written. Previously queued offline ciphertext is not decrypted or replayed.
- Text sends in degraded mode **await actual Supabase `send_message` RPC success**; a failure leaves text in the UI and reuses a per-session UUID on retry. Media/attachments and view-once are disabled in degraded mode to prevent untracked uploads. A process restart after lost RPC response can still result in duplicate retries, hence manual verification is necessary.
- Show an unmistakable warning in chat list and conversation screen. On normal secure cache success, the existing encrypted SQLite outbox, offline retries and media behavior are preserved.
- Add a **non-sensitive stage code** to the cache initialization error (`key-read`, `sqlite-open`, `sqlite-decrypt`, etc.) without ever logging cryptographic key, messages, file paths, or database contents. This is diagnostic only.
- Unit-test the fallback using a deliberately failing cache and test-server HTTP adapter. Real Android Keystore and SQLite failure must still be reproduced or diagnosed on device.

## Owner actions
1. **Do not uninstall or clear storage** on the affected Android device: local unsent drafts and key material may be unrecoverable if erased. Do not use a new app signature on top of a debug install without verifying signing compatibility.
2. Build a **connected** debug APK from `codex/cache-safe-online-recovery`, install **as an update** to the existing app, and test opening chats and sending a **short, non-sensitive test text**. Keep network connected. Successful online sends should appear in Supabase. Do not use production messages until key-cache recovery is confirmed.
3. Capture only the *stage code*, Android version and whether the installation was new or an update. For deeper diagnosis use device-local logcat but **do not upload complete logs** containing message bodies, tokens, PII or keystore metadata.
4. If fallback activates, old offline drafts remain preserved but are not auto-sent. A manual recovery procedure must identify whether the Keystore key is inaccessible, SQLite/WAL is malformed, or legacy migration differs. If no decryption key remains, encrypted drafts cannot be recovered cryptographically. Avoid silent fresh database creation; require informed consent for any eventual reset.
5. Independent backend issues, if any, still require normal RLS/SQL testing. The cache fix does not enable worker schedules, alter Supabase data, auth flags, or deploy release signing.
