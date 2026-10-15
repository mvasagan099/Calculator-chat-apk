# Phase 3 beta readiness

Recorded 2026-10-15 in the existing checkout. **Beta release remains blocked:** no installable APK, confirmed staging backend, provider media connection or physical-device result is available. No dependency versions or existing migrations were changed. Phase 2's historical report is preserved.

## Changes implemented

- Presence is bound to its original account, ignores late callbacks after disposal, clears typing/online state after disconnection and handles failed ephemeral sends without unhandled errors. Online publication now respects the same `last_seen_visible` preference as last-seen lookup. This is conversation presence, not a device-wide online directory.
- Private-session startup checks its mounted/account state after asynchronous preparation, settings and notification registration, preventing subscriptions and heartbeat timers from being installed after relock/disposal.
- Riverpod disposes the messenger repository. It tracks and removes its Realtime channels/timers, guards account changes, clears account-specific hidden-message state, and coalesces bursts of Realtime events. Message changes are filtered to the active conversation; receipt/reaction tables continue to rely on RLS because they have no conversation-ID column.
- Display order follows the database's `(created_at, id)` keyset ordering, including equal timestamps. Loaded history is refreshed by conversation-scoped, indexed ID batches of at most 50, so edits, soft deletions, reactions and receipts beyond the latest page refresh too. The encrypted cache retains up to 200 messages in each of the existing 20 cached conversations; explicitly paginated history can remain in the current screen's memory. Large-history query load still needs profiling.
- Outbox retries retain the original message UUID across restarts, await an active flush, drain messages enqueued during an in-flight send without waiting for the periodic timer, retry transient database/pool/transport failures and keep validation/permission failures available for explicit intervention. A 15-second request deadline bounds local cleanup waits; a late server commit is reconciled through the same UUID. Read acknowledgments are remembered only after success, allowing a later refresh to retry failed acknowledgments.
- Keyed message rows preserve attachment player state when new messages shift the list; reply previews display loaded originals or explicitly indicate an unloaded/deleted original, with animated selection feedback and drag-to-dismiss keyboard handling.
- Sending prevents repeated enqueue taps during the encrypted write and preserves text typed while it completes. Per-conversation Plain/Linen/Dusk wallpapers persist in the account's encrypted local cache. They are available under conversation options and do not require a database migration.
- Attachment forwarding uses bounded downloads, unique temporary directories and validated reuploads under the destination conversation. PostgreSQL tests reject source-path reuse across conversations and confirm destination members can read the copied object without gaining source access.
- Downloads reject invalid metadata, unexpected length, oversized chunks and truncated streams, canceling rejected streams. Upload progress is connected to image/file/voice composition. Image decode sizes are bounded in chat previews/viewers. Audio initialization uses a fresh signed URL, preserves playback speed, cancels its state subscription and avoids starting playback after its widget is disposed.
- Recorder/location/contact/forward operations check mounted state across asynchronous permission and transfer boundaries. Duplicate recorder operations are serialized; late recording startup is canceled after disposal.
- Local call teardown still starts before server communication. Failed terminal transitions now retry every five seconds while this controller remains alive, survive route reset, have a ten-second request deadline and cannot retry under a different account. The call screen indicates a pending server update. This queue is **in memory**; process termination/logout can prevent synchronization. Scheduled server cleanup and LiveKit room closure remain necessary.
- Added Android foreground location declarations for consent-based one-time sharing. Bluetooth audio selection explicitly requests Android 12+ Nearby devices permission without making it a prerequisite for ordinary microphone/speaker calls. The last-seen preference label now also describes online visibility.

The calculator, owner-bound PIN/Auth gates, seven migrations, six Edge Functions, private buckets, notifications and LiveKit integrations were retained. Existing group/status/media/call source is not new evidence of hosted success. No E2EE claim is made.

## Verification

| Command/check | Result | Evidence and scope |
| --- | --- | --- |
| `./scripts/flutterw pub get --enforce-lockfile` | PASS | [Log](phase3-pub-get.txt); lockfile unchanged |
| `./scripts/flutterw analyze --no-pub` | PASS | [Log](phase3-analysis.txt); no issues |
| `./scripts/flutterw test` | PASS | [Log](phase3-flutter-tests.txt); 53 passed, one hosted integration skipped |
| `./scripts/test-database.sh` | PASS | [Log](phase3-database.txt); seven migrations, read-only preflight, four PostgreSQL 17 authorization/media/status/call suites |
| Six Edge entry points plus hosted runner type check | PASS | [Log](phase3-edge-check.txt); cached, locked Deno dependencies |
| Edge security/privacy tests | PASS | [Log](phase3-edge-tests.txt); five tests |
| Public client configuration tests | PASS | [Log](phase3-config-tests.txt); 11 tests |
| Existing workflows, actionlint 1.7.7 | PASS | YAML validation; no executed workflow evidence |
| Android precache | PASS | Retained engine artifacts; does not supply missing Maven embedding coordinates |
| Doctor | Android toolchain PASS; warnings | [Log](phase3-doctor.txt); JDK 21/SDK 36/licenses available; SDK checkout channel metadata, unrelated web/Linux prerequisites and network checks have warnings |
| Debug build with `config/local.json` | BLOCKED, command exited 1 | [Log](phase3-debug-build.txt); generated ignored config is **preview only**, contains no service identifiers |
| Hosted acceptance runner | BLOCKED, exit 2 | [16 scenarios](phase3-hosted-results.json); no network requests or fake provider results |
| Android devices | BLOCKED | [ADB](phase3-devices.txt) lists no attached devices |
| Release build | BLOCKED / not attempted | No keystore or `android/key.properties` |

The 11 new Flutter tests cover stable ordering, retry classification, conversation-scoped history refresh, actual encrypted-file outbox/wallpaper restoration with an HTTP test adapter, presence expiration/disposal/failure, call-end retries/account isolation and bounded download streams. These adapters do not prove Supabase, LiveKit, Android plugins or FCM work.

## APK and network

The debug attempt failed fetching `io.flutter:flutter_embedding_debug:1.0.0-4c525dac5ebe5971c5708ef73558ed8edcf4a362` from the official Flutter Maven host. A separate HEAD request confirms **proxy HTTP 403 on CONNECT**, before TLS or any Google-origin response. Existing trusted network/toolchain settings were reused; TLS/checksums were preserved. Draft network settings are not proof that running egress policy changed. See [network evidence](phase3-network.txt).

There is no APK file, nonzero size, verified signature, package metadata, SHA-256 checksum or installation result to report. Expected debug path after success is `build/app/outputs/flutter-apk/app-debug.apk`, package `app.calculatorspace.calculator_messenger`, minimum API 29. Those are build requirements, not inspected APK properties.

The existing trusted GitHub Actions fallback remains `.github/workflows/android-debug.yml` on `codex/phase2-apk-verification`. It runs locked dependencies, analysis/tests, debug signing, APK inspection and artifact upload. Git access works; `api.github.com` is denied by the proxy, so a successful push is not a workflow PASS. No run ID or artifact checksum was observed. Successful artifacts are exactly `calculator-messenger-debug-preview` or, for a configured manual run, `calculator-messenger-debug-connected`. See [download and install procedure](RELEASE.md#github-actions-fallback).

## Deployment state

| Service | State / missing configuration |
| --- | --- |
| Supabase | No confirmed project URL/public key/link, remote schema/history or staging users. No migration/function deployment performed or verified. Existing seven migrations and six functions pass local checks. |
| Firebase | No matching Android console config, initialized project/device registration, server service account or real delivery evidence. Generic payload/helper policy tests pass. |
| LiveKit | No server URL/API credentials/webhook deployment or two actual participants. Token/authorization and controller tests pass locally; voice/video media is BLOCKED. |
| Android | Toolchain present; artifact egress blocked, no physical devices or private release signing configuration. Native changes have not compiled successfully. |

## Acceptance matrix

PASS below applies only to the explicitly identified local automated scope. Every hosted/device column remains separate. BLOCKED means a prerequisite is absent; no provider/device behavior was inferred from a mock or from source inspection.

| # | Scenario | Local automated evidence | Hosted / physical Android | Acceptance status |
| --- | --- | --- | --- | --- |
| 1 | Calculator works normally | PASS: engine/widget arithmetic and layouts | BLOCKED: no installable APK/device | PASS locally; device BLOCKED |
| 2 | Configured PIN unlocks messenger | PASS: verifier, confirmed preview setup, independent gate tests | BLOCKED: real Auth + Android not exercised | PASS locally; connected BLOCKED |
| 3 | Incorrect PIN never unlocks | PASS: verifier/throttle/calculator/gate tests | BLOCKED: Android not exercised | PASS locally; device BLOCKED |
| 4 | User registration | Existing hosted runner skipped/blocked | BLOCKED: staging Auth/SMTP/accounts absent | BLOCKED |
| 5 | Two users exchange messages | PASS: PostgreSQL authorization/idempotency | BLOCKED: real Realtime clients/accounts absent | BLOCKED |
| 6 | Read receipts synchronize | PASS: PostgreSQL receipt state | BLOCKED: hosted Realtime/device delivery absent | BLOCKED |
| 7 | Media transfers | PASS: size/byte helpers and storage/validation/forward policies | BLOCKED: hosted uploads, compression, recording/playback absent | BLOCKED |
| 8 | Offline messages recover | PASS: encrypted disk restart + HTTP adapter, stable ID; SQL idempotency | BLOCKED: real network loss/reconnect | PASS locally; hosted/device BLOCKED |
| 9 | Group messaging | PASS: PostgreSQL membership/admin authorization | BLOCKED: deployed group flow absent | BLOCKED |
| 10 | Voice calls connect | PASS: signaling authorization and controller cancellation/retry only | BLOCKED: no actual participant media | BLOCKED |
| 11 | Video calls connect | PASS: controller tests only | BLOCKED: no actual camera/media connection | BLOCKED |
| 12 | Background notifications arrive | PASS: generic payload/routing policy only | BLOCKED: Firebase/device configuration absent | BLOCKED |
| 13 | Private content stays locked | PASS: cold/background/idle/back/deep-link/dialog gate tests | BLOCKED: OEM recents/screenshots/biometrics/OS taps | PASS locally; device BLOCKED |
| 14 | Unauthorized access denied | PASS: real local PostgreSQL roles/RLS and Edge guard tests | BLOCKED: hosted gateway/Storage enforcement untested | PASS locally; hosted BLOCKED |
| 15 | APK installs and launches | Build command failed on dependency download | BLOCKED: no APK/device | BLOCKED |
| 16 | Logout and session recovery | Local gate/storage coverage; hosted flow unrun | BLOCKED: real login/refresh/logout/recovery/deletion absent | BLOCKED |

## Owner actions and next work

1. Apply/review the saved environment network settings for official Flutter Maven access and `api.github.com`; recheck actual CONNECT responses. Alternatively inspect the Actions run on the existing branch from GitHub. Only a completed, inspected artifact counts as APK success.
2. Confirm a dedicated Supabase staging project and follow [DEPLOYMENT.md](DEPLOYMENT.md): inspect remote schema/migration history and dry-run before deploying. Supply public client identifiers through ignored config/environment settings; server keys remain server-side.
3. Register Firebase's exact Android package and supply its console config through the public-config validator. Configure FCM service credentials, LiveKit secrets and signed webhook only in Supabase, plus the documented Cron/Vault workers. Never put test passwords or server keys into build variables.
4. Supply two disposable verified staging accounts using the ignored hosted-test config and explicit target/write consent described in [HOSTED_TESTS.md](HOSTED_TESTS.md). Replace the generated preview `config/local.json` with validated connected public config for provider testing.
5. Obtain and verify the debug APK and checksum, connect two Android devices, then run every acceptance case with real networks, recording/playback, calls and foreground/background/terminated notifications. Add release signing securely only for release builds.

Prioritize actual native compilation/provider acceptance next, followed by call process-death reconciliation, large-history/group load profiling, media-transfer cancellation, battery/memory measurements, OEM/background testing, accessibility and an independent security review. Beta readiness has not been established by the local suite alone.
