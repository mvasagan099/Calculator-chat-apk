# Phase 4 security delivery

Recorded 2026-10-15. Work continued in the existing checkout and branch. **Application E2EE and Android beta readiness remain blocked.** The calculator, existing messaging/call/notification integrations and original seven migrations were preserved. Application dependencies, lockfile and Android configuration were not replaced or upgraded.

## Feature status

IMPLEMENTED means production-path source exists; VERIFIED means only the named executable test scope passed. Neither means hosted/device certification.

| Feature | Status | Evidence / remaining scope |
| --- | --- | --- |
| Native Signal protocol evaluation | VERIFIED | 17 actual Java/JNI protocol checks on Linux, with pinned official artifacts |
| One-to-one application E2EE | BLOCKED | No validated Flutter/native store, ciphertext transport, trusted device-key directory or mobile integration; ordinary messages remain server-readable |
| E2EE attachments | BLOCKED | Native probe verifies Signal key transport plus standard GCM integrity/metadata binding; Flutter uploads remain ordinary media |
| Group/call E2EE | NOT IMPLEMENTED | No encrypted-group protocol or media E2EE claim |
| In-app identity verification/key-change warnings | NOT IMPLEMENTED | Native library refusal/safety-number change tested; no production crypto identities/UI |
| Disappearing messages | IMPLEMENTED | Per-chat future-message policy, server deadlines/RLS, tombstones, worker cleanup, local expiry and retained-media protection; local SQL/cache tests pass |
| View-once photos/videos | IMPLEMENTED | Service-only atomic recipient claim, direct Storage/forward/export denial, renderer closure and private temporary files; native playback/hosted delivery remain blocked |
| Approved device/account-session access | IMPLEMENTED | Opt-in approval, random local device UUID, request code, password-confirmed actions, device list/activity/revoke/revoke-others; local SQL and Auth adapter tests pass |
| Independent cryptographic device identities and encrypted history sync | NOT IMPLEMENTED | Device UUIDs/session approval are not cryptographic identities or Signal sessions |
| Online/last-seen/photo/invitation/receipt privacy | IMPLEMENTED | Separate settings; RLS/RPC/Storage controls tested locally |
| Calculator/PIN/relock/local cache | VERIFIED | Regression/controller/widget/encrypted-file tests; Android Keystore/biometric/OEM behavior unverified |
| Hosted Supabase/Firebase/LiveKit | BLOCKED | No confirmed project/configuration, staged accounts or actual participants |
| APK/signature/checksum/install | BLOCKED | Flutter embedding dependency returns proxy HTTP 403; no APK/device/signing configuration |

See [ENCRYPTION_DESIGN.md](ENCRYPTION_DESIGN.md) for evaluated libraries, the actual protocol probe, future key lifecycle, metadata, historical plaintext migration and the specific E2EE blockers. No insecure replacement key exchange or silent plaintext fallback was introduced.

## Retention and view-once implementation

- Conversation policies support Off, 24 hours, 7 days and 30 days in the UI. The RPC additionally validates custom values from 60 seconds to 30 days. Only group admins may change group policies; direct participants can change their shared policy. The banner is visible to participants. Changes apply to future messages, not existing history.
- Each new message receives a server-controlled expiration snapshot. RLS excludes expired messages and related records before cleanup. List previews/unread queries exclude them. Local lists, reply previews, encrypted caches/outboxes and retained full-screen media enforce known deadlines. Changes in policy not yet synchronized to an offline client cannot retroactively inform that client; server rules remain authoritative on reconnect.
- The maintenance worker purges up to 500 expired messages per invocation, cascading edits/reactions/receipts, queues Storage deletion and keeps minimal UUID/conversation tombstones to reject resurrection by stale retries. Media jobs survive message-row deletion and are acknowledged only after successful Storage removal. Cleanup is eventual and depends on a deployed, running worker; RLS denial is immediate at the server deadline.
- View-once is limited to one-to-one photos/videos. Sender controls select it explicitly in the attachment menu. Unopened content expires within 24 hours or sooner under the chat policy. Neither sender nor recipient obtains normal Storage URLs/attachment metadata for the attached object. A service-only, locked claim verifies current recipient membership, blocks, deadline and opened state before serving bytes through the authenticated Edge Function. A failed/interrupted opening remains consumed.
- The viewer exposes no export/forward controls. A second claim is denied across devices. Opening marks the durable message and queues object cleanup after two minutes. Image buffers/cache entries are released/evicted best effort; video files are app-internal with unique names, deleted on close/relock/background and swept after a cold restart. Both view-once and full-screen normal media close on expiry/relock, even when a navigator route is retained.
- New access rules do not revoke an already issued signed URL instantly. The app limits new URL lifetimes to the remaining message lifetime, but old/external capabilities can survive until URL expiry or object deletion. Screenshots/another camera, prior downloads, modified clients, backups and copies outside the app are not erasable guarantees. Current view-once storage is not E2EE.

## Device/session controls and limits

Device approval is **opt-in** under Settings → Devices and sessions, preserving existing account access until enabled. Enabling requires account-password confirmation and retains the acting session as approved. Another sign-in requests approval with an app-generated, securely stored device UUID and a short-lived random request code. The owner compares that code on an already approved device and confirms the account password. Device names are user-entered labels, not hardware attestation.

Each approved session is bound to the signed Supabase JWT's `session_id`. Restrictive policies add device authorization to existing user-data, Storage and Realtime authorization tables. Existing client SECURITY DEFINER RPCs are kept behind guarded wrappers, with originals moved to private/non-executable locations. Edge Functions check current device authorization after Auth. Push registrations are bound server-side to the current session, and workers select only currently authorized registrations. Revocation cannot be bypassed by changing the local UUID or refreshing a token for the same revoked session.

Local authorization is refreshed on entry, account/device events and heartbeat; initial unknown authorization fails closed. A previously approved, unexpired session tolerates temporary network loss for cached use. Revocation cannot remotely erase content already delivered to an offline device. Password reauthentication uses an isolated temporary Auth session so approval/PIN recovery does not accidentally replace the authorized session with a new unapproved login. Temporary proof-session revocation and all provider behavior still need hosted verification.

Revocation here withdraws **application access**, not a claim that every Supabase refresh token has been physically deleted. GetUser/Auth APIs remain Supabase-controlled. Existing bearer media URLs and established LiveKit streams have their documented residual lifetime; new call tokens are guarded but immediate provider media eviction is not verified. No messaging-key endpoint or per-device encryption identity has been shipped.

Do not enable approval until the schema, **all eight updated Edge Functions**, push worker and client are deployed together. Existing unregistered sessions then lose app-resource access. Keep an approved device available: there is deliberately no client-side self-approval/password-only bypass if all approved sessions are lost. Verified owner recovery requires a separately reviewed backend procedure; this is a rollout blocker for broad production use. Security audit rows contain operation/actor/session IDs, not message bodies, passwords, tokens or private keys.

## Local protection

The existing AES-GCM account-bound cache and Keystore-backed secrets remain. Known-expired content is pruned on reads/writes. Deleted cached bodies and received view-once bodies/attachment metadata are sanitized; the encrypted pending-send outbox retains upload metadata until delivery. Relocking suspends repository channels/retry timers, drains outstanding writes/sends and releases cache/key references while retaining encrypted history. Existing in-flight sends may finish, bounded by their request deadline. Flutter image cache eviction and primary view-once-buffer clearing are best effort, not forensic Dart/native/GPU erasure. Explicit storage clearing still deletes encrypted history and its stored key, including after suspension.

Cold launch, manual/background/idle locks, independent Auth/PIN gates, device approval, notification/deep-link checks and FLAG_SECURE remain active. No OS indicators/permission/foreground-service restrictions are bypassed.

## Automated evidence

| Check | Result | Evidence |
| --- | --- | --- |
| Flutter analysis | PASS | [Log](phase4-analysis.txt), no issues |
| Full Flutter tests | PASS | [Log](phase4-flutter-tests.txt), 66 passed; one hosted test skipped |
| Focused final privacy tests | PASS | [Log](phase4-focused-final.txt), 12 passed; [final view-once expiry regression](phase4-expiry-renderer.txt), three renderer cases passed |
| PostgreSQL 17 | PASS | [Log](phase4-database.txt), ten migrations, read-only preflight and seven transactional suites |
| Edge/helper/hosted runner type checking | PASS | [Log](phase4-edge-check.txt), eight entry points and two hosted runners |
| Edge security/privacy tests | PASS | [Log](phase4-edge-tests.txt), five tests |
| Native Signal prototype | PASS | [Log](phase4-signal-tests.txt), 17 real native-library checks; app E2EE disabled |
| Public configuration tests | PASS | 11 tests retained; build/secret input policy unchanged |
| Workflow lint | PASS | Existing APK workflow plus separate native-protocol CI job |
| Hosted Phase 4 runner | BLOCKED | [Six scenarios](phase4-hosted-results.json), missing staging config; no requests or mock PASS results |
| Debug APK | BLOCKED, exit 1 | [Log](phase4-debug-build.txt), official Flutter Maven artifact HTTP 403 |
| Physical Android | BLOCKED | [ADB](phase4-devices.txt), no devices attached |

The new Flutter tests exercise retention/legacy compatibility, real encrypted-file restart and cache-reference release, private file cleanup, Auth/device gates with an HTTP adapter, and view-once/retained-renderer lifecycle with a transport adapter. SQL tests use genuine PostgreSQL roles/RLS and transactions, not a simulated database. They do not replace Supabase Auth/Storage/Realtime gateway tests. JNI tests are genuine protocol operations but use in-memory test stores; they do not validate Android storage or delivery.

## Required security scenarios

| Scenario | Current evidence |
| --- | --- |
| Encryption/decryption and key agreement | PASS: native Signal probe only; application BLOCKED |
| Ciphertext tampering/replay | PASS: native probe; application transport BLOCKED |
| Rotation, delayed packets and identity changes | PASS: native probe; production identity UI/store BLOCKED |
| Offline encrypted delivery/session recovery | PASS: native in-memory serialized-session probe; real app E2EE BLOCKED |
| Multi-device encryption delivery | PASS: isolated per-device native sessions; production fan-out NOT IMPLEMENTED |
| Device revocation/authorization failures | PASS: local SQL plus Auth adapter; hosted BLOCKED |
| Disappearing expiration | PASS: SQL deadlines/tombstones and local/cache tests; scheduled hosted purge BLOCKED |
| View-once lifecycle | PASS: SQL atomic claims/Storage denial plus renderer tests; native/video/provider BLOCKED |
| Local cache/relock | PASS: encryption/tamper/expiry/reference-release and gate regressions; hardware BLOCKED |
| Session/PIN recovery | PASS: existing local gates and new device checks; real Auth/email/isolated-password flow BLOCKED |
| Encryption failure handling | PASS: native rejection checks; no production encrypted mode to fall back from |
| Real voice/video/notifications/install | BLOCKED: no configured providers, APK or devices |

## Build, deployment and owner steps

1. Apply/review environment networking for the official Flutter Maven host and GitHub Actions API. [Current network evidence](phase4-network.txt) still shows CONNECT denial. No APK, SHA-256 or successful CI run is available. Existing artifact names/download procedure remain in [RELEASE.md](RELEASE.md).
2. Confirm a dedicated staging Supabase target; inspect remote schema, grants and migration history before applying the three new additive migrations. Review the guarded RPC relocation carefully against any remote custom functions. Do not reset or repair an unknown production schema automatically.
3. Deploy all eight functions and the scheduled worker together, then use validated connected public config. Firebase/LiveKit/server credentials remain in provider settings; account passwords and service keys never belong in APK/CI public variables. The current ignored `config/local.json` is preview-only.
4. Run the new real-provider privacy runner using [DEPLOYMENT.md](DEPLOYMENT.md#phase-4-staging-privacy-validation). Ordinary write consent does not authorize device-approval activation. Its extra activation flags apply only to disposable accounts and may leave those accounts needing owner backend recovery/deletion after test sessions sign out. No such activation occurred here.
5. Obtain/inspect an actual APK, use two physical devices, and test video files, Keystore/biometrics, crash cleanup, token refresh/revocation, cold/background/terminated notifications, calls and release signing. Complete the native crypto bridge/provenance/store/delivery design before enabling E2EE.

Reusable environment startup guidance was updated with Phase 4 test commands and explicit encryption/build/provider limits. That saved draft does not apply network policy or publish an environment. No remote migrations, functions, provider services or signing material were deployed in this phase.
