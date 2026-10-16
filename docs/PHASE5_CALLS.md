# Phase 5 calling delivery

Recorded 2026-10-16 in the existing checkout and `codex/phase2-apk-verification` branch. No new application/worktree, remote migration, provider deployment, test account or signing identity was created. **Advanced calling has production-path source and local tests; working two-device/four-device media and an Android APK remain BLOCKED.** Application/message/call E2EE remains disabled.

## Status and evidence

IMPLEMENTED describes source; VERIFIED applies only to the named executable scope.

| Feature | Status | Evidence and limits |
| --- | --- | --- |
| Direct voice/video lifecycle | IMPLEMENTED | Preserved existing SDK integration; invitation, busy/waiting, timeout, cancellation, cleanup and authorization tests pass locally. No real media connection verified. |
| Group voice/video | IMPLEMENTED | Real LiveKit SFU rooms, per-member invitations/acceptance, join/rejoin/leave, host/admin termination/removal, participant grid/pinning/speaker/mute state and invitations. Four-member SQL tests pass; four-party audio/video and capacity are unverified. |
| Retry-safe initiation/concurrent actions | VERIFIED | Genuine PostgreSQL concurrent transactions return one call ID and serialize accept/cancel; terminal history is atomic. Flutter preserves the request ID across ambiguous transport errors. |
| Token authorization | VERIFIED | SQL checks current participant/member/block/device/session state. Actual signed test JWTs verify bounded 90-second voice/video grants. Real LiveKit admission remains BLOCKED. |
| Screen sharing | IMPLEMENTED | Installed SDK/MediaProjection consent, separate projection FGS, explicit start/stop, cancel/relock/end cleanup. Dart adapter/privacy tests pass; Android native compilation/capture/OS revocation remain BLOCKED. |
| Network/reconnection | IMPLEMENTED | SDK full/signal reconnect events, adaptive stream/dynacast, audio-only video unsubscription, measured network quality/available RTT/jitter/loss/bitrate. Unit state tests pass; Wi-Fi/mobile handover, packet loss, battery/CPU and Android audio routing are unverified. |
| Incoming notifications/actions | IMPLEMENTED | Generic high-priority data-only FCM calls, short deadline, local call-category notification and unlock actions. Payload/action parsing tests pass; actual foreground/background/terminated delivery remains BLOCKED. |
| Call waiting | IMPLEMENTED | Server prevents joining two calls; active-screen panel or alternate-call route offers decline or end-current/review. No automatic hold or second concurrent media session. |
| Call history | IMPLEMENTED | User-scoped outcomes, direction, timestamps, call-span duration and callback action. Provider synchronization/device UI unverified. Duration is call metadata, not a measured talk-time/billing guarantee. |
| Multi-device calling | NOT IMPLEMENTED / DISABLED | Only one authorized push registration is selected per invitation. Accepted-session binding prevents another session obtaining the same participant's media grant. Phase 4 approval is not hosted/device-verified. No synchronized multi-device ringing/answer resolution claim. |
| Picture-in-picture | NOT IMPLEMENTED | No PiP window bypasses the calculator/PIN boundary. Needs a separately tested privacy policy and Android lifecycle integration. |
| Android Telecom/ConnectionService | NOT IMPLEMENTED | Current mechanism uses call-category notifications and capture foreground services. No self-managed phone account, OS dialer integration or full-screen intent exemption is claimed. |
| Supabase/LiveKit/Firebase deployment | BLOCKED | No confirmed staging project, provider configuration/secrets or test accounts. |
| APK/install/signature/checksum | BLOCKED | Proxy CONNECT denies the official Flutter embedding host with HTTP 403; no APK/device/private release signing. |

## Backend migration 011

`202610160011_advanced_calls.sql` preserves all ten earlier migrations and existing calls/history. It adds group-call/request/update metadata, participant invitation state/deadlines, accepted Auth session, random media-join epoch and signed-webhook departure state. Existing participant rows receive compatible state defaults; no existing messages, encryption stores, device approvals or accounts are reset. Drain active calls before the coordinated rollout: legacy clients use different participant identities and do not understand the new invitation states.

- `begin_call` requires current membership/device access and an owner-scoped UUID request ID. A global transaction advisory lock serializes overlapping initiation/acceptance. Retrying the same request returns the same durable call, including a terminal result; it does not resurrect it. `start_call` remains a guarded compatibility entry point.
- Call creation snapshots current group members as invitations. A callee must explicitly accept before receiving a token. Another participant's group acceptance never grants all invitees access. Calls have a 45-second initial ring/invitation lifetime; later eligible invitations have their own deadline. An active group uses one room per conversation. New members can be invited; removed participants cannot rejoin that call.
- A busy callee may receive an invitation but cannot accept while joined to another live call. They must leave/end the current call or decline the waiting invitation. Group leave affects only that member; only the initiating host or current conversation admin can end for everyone/remove others. Terminal transitions and history are idempotent.
- `authorize_call` requires joined state, matching accepted Auth session, current membership/blocks, device authorization, accepted global call state and the existing two-hour hard lifetime. The caller gets no pre-answer media token. Token issuance is rate limited.
- LiveKit identity is `user_uuid:join_epoch_uuid`, generated by the database. Clients cannot choose room or identity. Rejoining after leaving rotates the epoch; queued eviction of an older epoch cannot target the new participant. The token allows one room, audio only for voice, or microphone/camera/screen-video for video; no screen audio/data/admin/recording grant. WebRTC transport protection is not application E2EE.
- The new authenticated `call-control` Edge Function commits authorized SQL state before attempting immediate LiveKit teardown/participant removal. Provider failure leaves durable cleanup work; maintenance retries and acknowledges only after removal. Direct RPC operations remain guarded and require maintenance for media cleanup.
- Maintenance rechecks membership, blocks and session approval. Signed LiveKit participant join/leave webhooks record epoch-bound departure timestamps; newer joins clear a departure and older events cannot overwrite them. A recorded disconnect gets 90 seconds for reconnect before reconciliation removes the participant. A direct call ends when a participant is removed; group peers continue. Same-second events conservatively prefer a join. The hard two-hour timeout remains a fallback, including clients that never establish media or missing webhooks.
- Device/membership revocation prevents new tokens. The app also rechecks authorization about every 15 seconds during a call, including while the calculator is locked; a definite denial closes local media, while a network outage leaves reconnection to LiveKit. Auth expiry/device denial observed locally closes the call. Existing media eviction depends on a functioning LiveKit API/worker. Previously issued capabilities cannot be promised to disappear instantaneously; a short initial token lifetime alone does not bound an already established media session.
- Call roster RLS preserves member/session checks. Service-only notification selection verifies the invitation and chooses **one** authorized session-bound registration. No new client-write table grants or secrets were added.

## Flutter and Android behavior

Existing calculator/PIN/Auth/device gates, encrypted local chat cache, view-once/expiration, messages, media and original calls are preserved. The existing `flutter_webrtc` 1.6.2+hotfix.4 dependency was promoted from transitive to directly pinned solely to use its documented capture-consent helper; no package version or binary was upgraded.

The group UI uses actual Room participants/tracks, responsive grids, active-speaker borders, participant pinning, microphone/camera controls, Bluetooth/output selection, invite/remove controls and a host end-for-all action. Camera denial/setup failure can retain audio; a failed camera foreground-service transition closes media safely. Speaker preference and tracks are cleaned up on teardown. SDK auto-reconnection reuses capture; explicit retry gets a fresh authorized grant. The optional network panel samples available SDK statistics every five seconds and leaves missing measurements unavailable; it does not fabricate quality/latency readings. Adaptive stream/dynacast and video unsubscription support lower-bandwidth audio fallback. No maximum participant capacity, codec performance or battery life has been certified.

Foreground microphone/camera capture starts only after user permission and native foreground-service readiness. MediaProjection uses an explicit system prompt, then a separate non-exported `mediaProjection` FGS; no projection starts merely from a notification. The scoped consent prompt tolerates Android's transient inactive dialog, like biometrics; real backgrounding, manual lock, inactivity timeout or cancellation still invalidates it. Sharing ends on relock/end. A network reconnect can resume the same explicitly authorized sharing track; relock/end destroys it and late consent cannot restart it. FLAG_SECURE is retained: private app content can appear black in capture. With default background relocking, switching to another app stops sharing. Sharing other apps requires the owner's existing opt-in to retain unlock while backgrounded; mandatory screen-sharing indicators/notifications remain visible. These native paths need Android 10/13/14+ tests before release.

While locked, call notifications say only “Calculator / New activity,” with **Unlock to answer** and **Unlock to reject** actions. Neither exposes names/photos/conversations. Answer intent opens the protected call screen after Auth/device/PIN validation and still requires explicit Answer before capture. Reject intent is executed only after that validation. Ending an already-active call through its mandatory generic foreground notification is permitted without revealing history. Locked UI stays the calculator during an ongoing, explicitly initiated call; an end does not automatically unlock it.

Incoming calls use high-priority data-only FCM so the supported background handler can show action notifications. It never downloads private messages, grants or credentials or starts capture. Expired/malformed invitations do not ring. Foreground/background isolates use the same call notification ID. This is **not guaranteed delivery**: notification permission, Doze/OEM policy, network, process limits and FCM deprioritization apply. Force-stopped apps generally receive nothing until manually opened; terminated and force-stopped are different states. No full-screen intent, background activity launch or while-in-use permission restriction is bypassed. No Telecom/phone-call FGS exemption is assumed.

## Tests and build

| Check | Result | Scope |
| --- | --- | --- |
| Locked dependency resolution | PASS | `pub get --enforce-lockfile` |
| Flutter analysis | PASS | [Log](phase5-analysis.txt) |
| Flutter tests | PASS | [Log](phase5-flutter-tests.txt), 83 passed; one hosted skip |
| Focused call/privacy tests | PASS | [Log](phase5-call-tests.txt); adapters, not devices |
| PostgreSQL 17 | PASS | [Log](phase5-database.txt), 11 migrations/preflight, eight transactional suites plus two actual concurrent transaction checks |
| Edge type checking | PASS | [Log](phase5-edge-check.txt), nine entry points/two hosted runners |
| Edge tests | PASS | [Log](phase5-edge-tests.txt), seven checks, including genuine test-JWT signature/claims |
| Public config validation | PASS | [Log](phase5-config-tests.txt), 11 tests |
| Native Signal regression | PASS | [Log](phase5-signal-tests.txt), 17 checks; app E2EE still disabled |
| Workflow lint | PASS | Existing trusted Android build workflow preserved |
| Hosted provider runner | BLOCKED | [Report](phase5-hosted-results.json), 16 scenarios blocked, exit 2, no network/mock PASS results |
| Debug APK | BLOCKED | [Log](phase5-debug-build.txt), exit 1, official Flutter Maven HTTP 403 |
| Physical devices | BLOCKED | [ADB](phase5-devices.txt), no attached devices |

Local SQL and JWT tests establish authorization/state properties only. They do not prove a LiveKit server accepted the token, an SFU forwarded media, native services compiled, Android captured a screen, Firebase delivered a notification or an APK installed. No APK file, SHA-256, completed CI run or release signing result is available. GitHub Actions API access is unavailable from this instance; pushing the existing workflow is not build evidence.

## Acceptance matrix

| Scenario | Local evidence | Hosted/device result |
| --- | --- | --- |
| Voice/video initiation and acceptance | PASS: SQL, controller adapters and signed token tests | BLOCKED |
| Reject, cancel, missed/busy and ring timeout | PASS: SQL/controller paths | BLOCKED |
| Concurrent retry and accept/cancel | PASS: actual concurrent PostgreSQL transactions | BLOCKED at providers |
| Reconnection without duplicate capture | PASS: controller adapter plus webhook/grace SQL | BLOCKED for Wi-Fi/4G/5G/packet loss |
| Four-member voice/video join/leave/invite | PASS: real SQL authorization/state | BLOCKED for actual SFU media/capacity |
| Participant removal, current membership/blocks | PASS: SQL/revocation tests | BLOCKED for actual media eviction |
| Room token scope/identity/lifetime | PASS: SQL + real test-JWT signature/claims | BLOCKED for server admission |
| Call waiting | PASS: server busy state; source UI | BLOCKED for device interaction |
| Notification metadata/actions | PASS: payload/parser tests | BLOCKED for foreground/background/locked/terminated/offline/force-stop delivery |
| Calculator lock/session revocation | PASS: prior gate regressions and new consent/authorization tests | BLOCKED for Android native behavior |
| Media/foreground-service cleanup | PASS: controller/transport adapter tests | BLOCKED for actual SDK tracks/Android FGS |
| Screen-share permission/cancellation lifecycle | PASS: privacy/controller adapters | BLOCKED for MediaProjection/system stop/rotation |
| Multi-device calling | NOT TESTED: deliberately disabled | BLOCKED on Phase 4 validation/design |
| PiP/Telecom | NOT IMPLEMENTED | NOT TESTED |
| APK install/launch/signature | BLOCKED by build | BLOCKED |

## Deployment and next steps

1. Restore trusted official Flutter Maven access or inspect a successful run of the existing Android Actions workflow. Expected artifact after success: `calculator-messenger-debug-preview` (or configured `...-connected`). [RELEASE.md](RELEASE.md) gives download, checksum/signature and installation commands. [Current proxy evidence](phase5-network.txt) records CONNECT 403 (curl exit 56). No untrusted mirrors/TLS bypass/fake embedding packages were used.
2. Confirm a dedicated staging project, inspect schema/migration history and back up before the additive migration 011. Drain active calls; review wrappers/policies against remote custom changes. Do not deploy an unknown target/reset existing data.
3. Deploy all nine functions, including **call-control**, updated token/push/maintenance/webhook functions and the Phase 4 device guards together. Configure server-side LiveKit API credentials, HTTPS/WSS/TURN connectivity, signed webhooks for participant_joined/participant_left/room_finished, and scheduled maintenance/push. Keep secrets out of the APK. Configure Firebase Android package/resources and notification permissions.
4. Use two real test accounts/devices for voice/video; then four devices/accounts in one group. Verify permission denial, speaker/earpiece/Bluetooth, foreground/background/locked/terminated/offline/force-stop notifications, waiting, ending from notification, session revocation, group removal, reconnection and MediaProjection consent/system stop. Inspect Android logs/merged services, release variants and CPU/battery/track counts. Record each result; no PASS can be inferred from this report.
5. Multi-device calling, PiP and Telecom remain separate engineering/validation work. Phase 4 cryptographic mobile integration and production recovery also remain unfinished; this phase does not certify E2EE or overall beta readiness.
