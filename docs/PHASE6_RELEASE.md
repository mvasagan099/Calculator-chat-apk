# Phase 6 release audit (historical)

Later evidence: the owner reports a successful preview APK build/static verification and Android installation. The no-artifact statements below describe only the original Phase 6 checkpoint. Connected APK, hosted services and two-device verification remain unverified; see [Phase 7](PHASE7_ACTIVATION.md).

Recorded 2026-10-16 (Asia/Kolkata). Existing checkout/branch preserved; no worktree, app recreation, dependency upgrade, remote deployment or public app publication occurred. **Classification: DEVELOPMENT — NOT PRODUCTION READY.** No APK/AAB or install result exists.

## Changes and demonstrated fixes

A conversation/message response begun before relock/account change could write into the repository's newly current cache. A delayed hide request could also remove another account's cached copy. Four HTTP-adapter/encrypted-file tests failed on the previous implementation, then passed with the fix. [Before-fix reproduction](phase6-isolation-before.txt) is historical failure evidence, not a current regression failure.

Cache callbacks now capture the authenticated owner, exact cache instance and session generation. They revalidate before requests and after asynchronous reads before any cache/hidden-state mutation. Old message streams stop emitting; an obsolete page cannot issue a follow-up hide query for the newly signed-in owner. Storage clearing invalidates subscriptions/generation through suspension, and abandoned initialization releases its cache/key references. Existing outbox persistence, stable UUID retry, pagination, relocking and encrypted history are preserved. [Focused checks](phase6-isolation-tests.txt), [full regressions](phase6-flutter-tests.txt). These are local adapter tests, not hosted account verification or forensic memory erasure.

Release tooling now refuses missing signing inputs, preserves existing owner configuration, materializes CI files with private permissions, verifies the actual certificate with JDK keytool, and cleans only generated files. Gradle refuses release tasks when signing configuration/keystore is absent; debug builds remain available. No keystore is generated for the app, and no debug-signing fallback exists.

APK inspection now checks the target API (36), exact package/minimum API/launchable activity, signer fingerprint for release, and root/nested private configuration plus escaped private-key material. Checksums use the actual artifact filename. Structured inspection JSON explicitly leaves installation and hosted services unverified. AAB inspection verifies every content entry using standard JDK JAR-signature verification and the owner's pinned certificate, plus bounded known-secret scanning. **AAB manifest/package/API inspection still requires official bundletool; an AAB is not directly installable.** Tests use temporary ZIP/JDK-signed JAR fixtures and disposable test keys, never a real Flutter artifact or owner release key.

The existing debug workflow remains manually dispatchable and uploads only after signature/metadata checks. A new **Signed Android development artifacts** workflow requires manual acknowledgement, protected source and an owner-configured `android-release` environment. It builds internal APK/AAB artifacts only after public-config validation, locked analysis/tests and certificate-verified signing setup. It neither publishes to Play nor creates GitHub Releases. Required reviewers/deployment-branch restrictions must be configured by the owner; workflow YAML does not create these protections or credentials. No successful workflow was inspected from this instance.

All 11 migrations, nine Edge Functions, dependency versions/lockfile, package identity, launcher assets, calculator/PIN design and previous functionality are preserved. No new backend migration was needed for the demonstrated client-cache defect.

## Major-feature audit

| Feature | Classification | Evidence and limitation |
| --- | --- | --- |
| Calculator/arithmetic/responsive shell | IMPLEMENTED; AUTOMATED TESTED | Flutter unit/widget regressions; DEVICE VERIFIED remains BLOCKED |
| PIN, persistence/throttling, unlock routing | IMPLEMENTED; AUTOMATED TESTED | Salted PBKDF2, secure-store adapter and gate tests; Android Keystore/biometrics/OEM behavior BLOCKED |
| Supabase Auth/email/profile/discovery | IMPLEMENTED; AUTOMATED TESTED in local adapter/SQL scope | No HOSTED VERIFIED accounts or deployment |
| Durable/realtime/private/group messages and receipts | IMPLEMENTED; AUTOMATED TESTED locally | Real two-user/device delivery, SMTP/Realtime gateways BLOCKED |
| Media/voice/file/contact/location paths | IMPLEMENTED; AUTOMATED TESTED in named local scopes | Actual upload, recording, playback, native permissions and hosted Storage BLOCKED |
| Direct/group LiveKit calls | IMPLEMENTED; AUTOMATED TESTED for state/auth/cleanup | Actual two-device/four-device SFU media BLOCKED |
| Call waiting/reconnection/screen sharing | IMPLEMENTED; AUTOMATED TESTED with adapters/SQL | Native capture, audio routing, handover, capacity and FGS behavior BLOCKED |
| FCM/private notifications/actions | IMPLEMENTED; AUTOMATED TESTED for payload/gates | Console config, real tokens/rotation and all OS delivery states BLOCKED |
| Status/expiry, membership, blocks/privacy | IMPLEMENTED; AUTOMATED TESTED locally | Scheduled hosted cleanup/provider integration BLOCKED |
| Disappearing/view-once controls | IMPLEMENTED; AUTOMATED TESTED locally | Hosted claims/deletion, real playback/Android capture protection BLOCKED |
| Local encrypted cache and device access approval | IMPLEMENTED; AUTOMATED TESTED | Account access approval is not cryptographic device identity; hosted approval/revocation/recovery BLOCKED |
| Signal native protocol evaluation | AUTOMATED TESTED | 17 actual native checks; not a Flutter encryption integration |
| Application/message/attachment/call E2EE | NOT IMPLEMENTED in production transport | Private/direct/group messages/media remain server-readable; no E2EE claim |
| Cryptographic multi-device sync/calling | NOT IMPLEMENTED / disabled | Independent keys/rosters/fanout and Phase 4 hosted/device proof unfinished |
| PiP, Telecom/ConnectionService, optional SMS OTP/contact sync | NOT IMPLEMENTED | No hidden OS exemption or simulated feature |
| Crash reporting | NOT IMPLEMENTED | No authorized provider configured; no additional telemetry introduced |
| APK/signed release/AAB | BLOCKED | Official artifact proxy 403; owner signing absent |

No feature is classified HOSTED VERIFIED or DEVICE VERIFIED in this phase.

## Automated results

| Check | Result | Evidence |
| --- | --- | --- |
| Flutter doctor | PARTIAL | [Log](phase6-doctor.txt): Android SDK 36/JDK 21/licenses pass; pinned SDK commit matches; proxy resources fail. Web/Linux desktop omissions are not Android prerequisites. |
| Locked dependency resolution | PASS | [Log](phase6-pub.txt), package versions/lockfile unchanged |
| Flutter analysis | PASS | [Log](phase6-analysis.txt), no issues |
| Flutter tests | PASS | [Log](phase6-flutter-tests.txt), **87 passed**, one hosted skip |
| New isolation + repository focused checks | PASS | [Log](phase6-isolation-tests.txt), eight checks; four new tests reproduced the original defects |
| PostgreSQL 17 | PASS | [Log](phase6-database.txt), 11 migrations/preflight, eight suites and two actual concurrent transaction checks |
| Edge type checks | PASS | [Log](phase6-edge-check.txt), nine entry points/two hosted runners |
| Edge security/token/payload tests | PASS | [Log](phase6-edge-tests.txt), seven tests |
| Release/config/signature tooling | PASS | [Log](phase6-tooling-tests.txt), **29 tests**, including real JDK fixture signatures and certificate setup/cleanup; no Flutter artifact verification implied |
| Native Signal regression | PASS | [Log](phase6-signal-tests.txt), 17 checks; app E2EE disabled |
| Workflow lint | PASS | Debug, backend/prototype and signed-development workflows |
| Hosted general/privacy runners | BLOCKED | [16 scenarios](phase6-hosted-results.json), [six privacy scenarios](phase6-privacy-hosted-results.json); both exit 2 with no provider requests |
| Debug build | BLOCKED, exit 1 | [Log](phase6-debug-build.txt), official embedding dependency HTTP 403 |
| Signing preflight | BLOCKED, exit 2 | Missing owner signing inputs; no private files/keystore generated |
| Android device tests | BLOCKED | [ADB](phase6-devices.txt) is empty; no KVM/device infrastructure available |

SQL/adapter/native fixture checks do not constitute an independent penetration test, hosted RLS certification, Android compilation or two-device calling proof. Known-secret scans cannot detect every encoded credential. No benchmark, external account, APK install, real push token or voice/video connection was fabricated.

## Build investigation

Flutter is 3.44.0/Dart 3.12.0 at pinned framework commit `559ffa3f75e7402d65a8def9c28389a9b2e6fe42`, engine `4c525dac5ebe5971c5708ef73558ed8edcf4a362`. Android SDK/build tools 36.0.0, Temurin JDK 21.0.12.1 and accepted Android licenses are available. AGP 9.0.1/Kotlin 2.3.20 and the existing compatibility switches were retained. Doctor's unknown SDK channel/upstream warning does not change the checked framework commit; no upgrade/channel switch was used to hide it.

Doctor and [curl](phase6-network.txt) independently show **proxy CONNECT denial (HTTP 403)** before TLS to the official artifact host. Cached engine/precache files do not provide the missing Maven embedding coordinates. The debug build reaches Gradle configuration but fails dependency resolution. Native app Kotlin compilation, APK packaging and installation remain unverified. No TLS bypass, fake Maven package, checksum change or untrusted mirror was used. GitHub Git access works, while [Actions API CONNECT](phase6-actions-status.txt) is denied; these are different operations.

Current ignored `config/local.json` is validated **preview-only**, with no provider identifiers. No `key.properties`, Firebase Android file, linked Supabase ref or hosted-test config exists; provider/signing environment variable presence is recorded without values in [prerequisites](phase6-prerequisites.json). No signed release/APK/AAB build was attempted without valid signing. Required future paths are expected outputs only:

- Debug: `build/app/outputs/flutter-apk/app-debug.apk`
- Signed APK: `build/app/outputs/flutter-apk/app-release.apk`
- Signed bundle: `build/app/outputs/bundle/release/app-release.aab`

**Actual artifact paths/checksums: none.** See [RELEASE.md](RELEASE.md) for owner setup, signing fingerprints, future CI artifact names/download and installation commands.

## Release gates

| Gate | Result | Reason |
| --- | --- | --- |
| A — nonzero APK installed | BLOCKED | Build dependency access and no Android device |
| B — two real Auth accounts | BLOCKED | No confirmed/deployed staging project or test credentials |
| C — independent-device messaging | BLOCKED | No provider/accounts/APK/devices |
| D — actual audio/video | BLOCKED | No LiveKit deployment/media participants |
| E — calculator protection in app/OS | BLOCKED for release | Flutter gate/relock/privacy regressions pass; APK/native notification/recents/biometrics checks unavailable |
| F — authorization/security regression | PASS in local automated scope | SQL/RLS, token, PIN/cache, media/payload and fixture-integrity tests pass; hosted/actual-artifact security remains unverified |
| G — critical-flow stability | BLOCKED | No installed build/device acceptance or performance trace |

The passing local component of Gate F does not override any blocked mandatory gate or certify production security. No production-ready or beta-ready claim is made.

## Performance and privacy findings

The demonstrated cache race is fixed; stale callbacks cannot write across owners or revive a fresh unlock's cache. Clearing storage now cancels repository channels/timers before discarding account data. Existing message windows remain bounded (50-row pages, batches of 50 IDs, 200 cached rows/chat and 20 cached chats), UUID idempotency/outbox limits, debounced refresh, lifecycle checks, image bounds and SDK adaptive streaming remain. These are source/local-test findings, not measured latency/CPU/battery improvements.

Mid-range device profiling is BLOCKED. After a real profile build, measure cold calculator startup; 20 chat navigations, pagination/reconnect and image viewing cycles; five completed calls; and a sustained call with Wi-Fi/mobile switching. Use Android Studio/Flutter DevTools with disposable data, record frame-time/memory/CPU trends and track/notification cleanup. Compare retained heap after GC across cycles and package-scoped battery use; do not upload raw message dumps, tokens, signed URLs, whole-device bugreports or private heap captures. No crash reporter is enabled without authorized configuration.

Local AES-GCM/Keystore-backed storage is separate from E2EE. View-once/expiry cannot erase external screenshots/backups/copies; old signed URLs and established media require their documented expiry/cleanup. Device approval is opt-in, and loss of all approved sessions still needs a reviewed owner recovery process. [SECURITY.md](SECURITY.md), [ENCRYPTION_DESIGN.md](ENCRYPTION_DESIGN.md).

## Owner actions

1. Apply trusted environment access for official Flutter/Google Maven hosts and GitHub Actions API, or inspect/run the existing trusted CI. No extra GitHub token is requested: Git works through the platform proxy; API denial is a network blocker. Verify an actual artifact/signature/checksum before installation.
2. Confirm a dedicated staging Supabase target and backup/schema/migration history. Follow [DEPLOYMENT.md](DEPLOYMENT.md); deploy the reviewed 11 migrations/nine functions together, configure SMTP/verification/redirects, private Storage/Realtime, scheduled workers and signed LiveKit webhooks/TURN. Supply provider secrets through provider/environment settings only. Nothing was deployed here.
3. Configure matching Firebase Android public resources, LiveKit server credentials and two disposable verified accounts. Run the hosted runners with exact target/write consent. Do not enable device approval without an approved device/recovery plan; the special disposable-account approval runner has separate activation consent.
4. Obtain a debug APK, then follow [the exact 20-case phone procedure](DEVICE_ACCEPTANCE.md) on two Android devices, and additional group/screen-share cases on four devices. Preserve existing installs/data on certificate mismatch; never automatically uninstall/clear personal data.
5. Configure a private owner keystore, certificate pin and the protected CI environment only for internal signed artifacts. Inspect the AAB with official bundletool and test generated APKs. Complete [store-policy/disclosure review](STORE_REVIEW.md); live official policy pages were blocked here. No public publication is authorized/performed.

Reusable environment startup guidance was saved separately; a draft save does not provision providers, apply egress policy or publish an environment.
