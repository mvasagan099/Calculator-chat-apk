# Validation evidence and release checklist

## Current Phase 6 evidence

**87 Flutter tests pass; one hosted test is skipped.** Analysis and locked resolution pass. Eleven migrations, eight PostgreSQL suites plus two concurrent transaction checks, nine Edge entry points/two hosted runner type checks, seven Edge tests, 29 release/config/signature tooling tests and 17 native Signal checks pass. [Full audit/gates](PHASE6_RELEASE.md), [device procedure/report](DEVICE_ACCEPTANCE.md).

Four new cache-isolation tests failed before the fix and now pass. They use HTTP adapters and actual encrypted files, not deployed Supabase accounts. JDK-signed JAR/ZIP fixtures and disposable test signing keys test verifier/configuration behavior, not Flutter APK/AAB signatures or installability. Neither missing signing inputs nor blocked provider requests are PASS outcomes. Existing commands below apply; tooling tests now require the same JDK 21 used by Android/CI. No source dependency versions were upgraded.

## Historical Phase 5 evidence

**83 Flutter tests pass; one hosted test is skipped.** Analysis and locked resolution pass. Eleven migrations, eight PostgreSQL suites and two real concurrent transaction checks pass. Nine Edge Functions and two hosted runners type-check; seven Edge tests (including actual test-JWT signature/claims), 11 config tests and 17 native Signal regressions pass. See [PHASE5_CALLS.md](PHASE5_CALLS.md) for scope, logs and the device/provider matrix. No APK/provider/media/device success is claimed.

```sh
./scripts/flutterw pub get --enforce-lockfile
./scripts/flutterw analyze
./scripts/flutterw test
./scripts/test-database.sh
deno check --config supabase/functions/deno.json supabase/functions/*/index.ts supabase/tests/hosted*.ts
deno test --allow-env=BUF_BIGINT_DISABLE --config supabase/functions/deno.json supabase/functions/_shared/*_test.ts
python3 -m unittest discover -s scripts/tests -p '*_test.py'
```

`BUF_BIGINT_DISABLE` is the installed protobuf runtime's non-secret feature switch, read at import; no other environment/network test permission is required. The SQL harness creates a disposable pinned PostgreSQL container with no published ports and runs concurrent transactions only inside it. No hosted database is used by these tests.

## Historical Phase 4 evidence

Full Flutter suite: **66 passed, one hosted integration skipped**. Analysis passes. Ten migrations and seven real PostgreSQL suites pass; eight Edge entry points and both hosted runners type-check; five Edge tests and 11 public-config tests pass. The separate official native Signal/JNI probe passes 17 checks. These are distinct test scopes; the Flutter app is not E2EE-enabled. See [PHASE4_SECURITY.md](PHASE4_SECURITY.md) for the scenario/status table and current logs.

```sh
SIGNAL_PROTOTYPE_CACHE=/workspace/toolchains/libsignal-prototype python3 scripts/test-signal-prototype.py
deno check --config supabase/functions/deno.json supabase/functions/*/index.ts supabase/tests/hosted*.ts
```

The native runner verifies pinned Maven artifacts before loading them and uses in-memory test stores. The six new hosted privacy scenarios are BLOCKED without staging configuration; they are not mocks. Renderer tests use an explicit transport adapter and cannot prove Android video, Storage delivery or screenshot behavior. Auth gate tests use an HTTP adapter and do not verify real password/token services. Actual signed APK/device/provider checks remain blocked.

## Historical Phase 3 evidence

- Flutter 3.44.0 / Dart 3.12.0 analysis: passed, no issues at the last recorded run; rerun after changes.
- Flutter unit/widget suite: **53 passed, one hosted integration test explicitly skipped** in the last recorded full run. It covers arithmetic precedence/errors, salted PIN verification, persistent throttling, corrupt-storage failure, calculator interaction, cold lock/route protection, both authorization gates, background/inactivity relocking, encrypted cache restoration/tamper rejection/account binding, serialized cache writes, retained-modal masking, onboarding navigation and landscape layout. The Phase 1 additions cover confirmed 4–8 digit PIN setup, leading-zero PINs, verifier namespace isolation, failed secure writes, full local navigation/search/theme changes without a backend client, arithmetic results that resemble a PIN, restart persistence, deep-link/background/back-button protection, compact/landscape layouts and late verification after relock/disposal. Test PIN derivations use a reduced work factor for speed; production remains 600,000 iterations. Fourteen call-controller regression tests cover cancellation during token/permission/connection/native-start waits, immediate local teardown before a pending server response, stale accepted/accept responses, cleanup across new calls and same-ID retries, control failures, transport loss, terminal server events and disposal. These controller tests use test-only adapters; they do not exercise real LiveKit capture or the Android foreground service.
- Revalidated in Phase 3: all six Supabase Edge Function entry points: Deno type-check passed using Deno 2.9.6 and a locked dependency graph.
- Edge security/privacy helper tests: **5 passed** for authentication requirements, body/UUID validation, file-signature/type rejection and generic/private notification payload policy.
- Fresh PostgreSQL 17 migration runs and four transactional security suites: passed. These use genuine roles, RLS, grants, triggers and functions. They check outsider conversation/message/call denial, sender spoofing denial, idempotency, delivery/read updates, edit ownership, group escalation denial, recipient-bound invitations, blocking, valid call transitions, anonymous privileged-RPC denial, storage membership isolation, mandatory server validation, forged validation denial and deleted-media read denial. Call token tests also cover unanswered-callee denial, blocks added after invitation, removed peer membership, expiry and terminal-call denial.
- Android debug build: **failed again in Phase 3** at dependency download because `storage.googleapis.com` returned HTTP 403. The missing JDK compiler was fixed first with an official checksum-verified Temurin 21.0.12.1 installation. The final failure remains network access, not a proven successful native compilation.

Tests do not establish that a hosted Supabase project, Firebase delivery or real LiveKit calls work. No providers were configured and no physical Android devices were attached. The updated Kotlin permission and foreground-service code has not compiled successfully in this instance. The source includes an Android integration calculator test, but it has not run on a device. CI configuration exists; no completed remote workflow or artifact has been observed.

Historical Phase 3 outputs: [analysis](phase3-analysis.txt), [Flutter tests](phase3-flutter-tests.txt), [debug build](phase3-debug-build.txt), [Edge checks](phase3-edge-check.txt), [Edge tests](phase3-edge-tests.txt), [PostgreSQL suites](phase3-database.txt), and [hosted results](phase3-hosted-results.json). Phase 1/2 historical logs are retained; no release build was attempted in Phase 3 without a keystore. See the [Phase 3 acceptance matrix](PHASE3_BETA_READINESS.md#acceptance-matrix).

Phase 3 adds 11 tests for equal-timestamp ordering, transient/terminal retry classification, scoped paginated-history refresh, encrypted outbox/wallpaper restoration across repository restart with an HTTP adapter, presence expiration/disposal/network failures, terminal call retry/account isolation and exact bounded download streams. The PostgreSQL media suite now rejects cross-conversation attachment-path reuse and checks the independently validated destination copy. These local results do not establish hosted transfer or call success.

## Reproduce local checks

```sh
./scripts/flutterw pub get --enforce-lockfile
./scripts/flutterw analyze
./scripts/flutterw test
./scripts/test-database.sh
deno check --config supabase/functions/deno.json supabase/functions/*/index.ts
deno test --allow-env=BUF_BIGINT_DISABLE --config supabase/functions/deno.json supabase/functions/_shared/*_test.ts
```

The SQL harness starts a pinned PostgreSQL container with no published ports and removes only its own test container. Its bootstrap is test-only scaffolding for Supabase schema contracts. It does not mock database operations; it also does not replace testing actual Supabase Auth, Storage, Cron or Realtime infrastructure.

For the hosted integration test, create two disposable verified email/password users in the deployed project, enable read receipts and ensure they do not block each other. In an ignored JSON file supply the public Supabase URL/key plus `TEST_A_EMAIL`, `TEST_A_PASSWORD`, `TEST_B_EMAIL`, `TEST_B_PASSWORD`. These test passwords are secrets: never commit the file, use production accounts, or paste them in chat. Run:

```sh
./scripts/flutterw test test/backend_integration_test.dart --dart-define-from-file=config/integration.json
```

It authenticates two real clients, waits for an authenticated Realtime subscription, sends the same ID twice, verifies one durable row and receipt synchronization, then soft-deletes its test message. It modifies the test accounts' direct conversation. It is not a two-physical-device test.

## Phase 1 device check (unrun)

The default build is `LOCAL_UI_PREVIEW=true`, with a separate local verifier. On an attached Android 10+ device, a fresh installation first asks for PIN creation/confirmation; subsequent cold launches show the calculator. The device integration test handles that first-time setup and calculates 8 × 7:

```sh
./scripts/flutterw test integration_test/calculator_device_test.dart -d DEVICE_ID
```

This test creates a test PIN only on an unconfigured local preview. Use a disposable installation. Device checks still needed include actual Keystore persistence/failure handling, biometric enrollment/prompt/cancellation, recent-app masking, Android back navigation and release installation. The tests below describe connected-mode acceptance for later phases.

## Hosted staging checks

See [HOSTED_TESTS.md](HOSTED_TESTS.md) for the expanded real-provider runner. All 16 required provider/device scenarios currently report BLOCKED. It requires explicit staging write consent, never uses admin credentials, and cannot verify real WebRTC media or Android behavior. The workflow/config tools also have 11 passing Python tests; workflow YAML passes actionlint.

## Required two-device acceptance (all unrun)

Use two physical Android devices, two independent verified accounts, production-like provider configuration and a signed release build. Record Android versions, APK hash/certificate, provider project, network conditions and actual pass/fail results for each scenario.

| Scenario | Expected result | Current evidence |
| --- | --- | --- |
| Calculator arithmetic | Precedence, decimals, percent, clear/delete and errors work | Unit/widget passed; device unrun |
| Correct/incorrect PIN | Only the configured PIN plus `=` opens private UI | Verifier/gate tests passed; device unrun |
| Cold launch, recent-app preview | Calculator first; no sensitive preview | Gate tested; OEM/device unrun |
| Background/inactivity, return button | Relock closes private routes immediately | Widget tested; device unrun |
| Registration/verification/login/reset | Real email flow, valid refresh/logout | Hosted/device unrun |
| A→B and B→A messaging | Durable, instant delivery without duplicate IDs | SQL passed; hosted/device unrun |
| Delivered/read privacy | Receipts synchronize; opt-out respected | SQL passed; hosted/device unrun |
| Replies/reactions/edits/deletes/search | Correct permissions, limits and pagination | SQL partial; device unrun |
| Offline and reconnect | Encrypted cache accessible after unlock, stable-ID sends reconcile after retries | Encrypted restart/HTTP-adapter/SQL idempotency tested; device unrun |
| Media, voice, exports | Valid files upload/download, play/pause/speed, reject bad types | Security checks passed; device unrun |
| Voice call | Two physical microphones/speakers exchange audio | Unrun |
| Video call and switching | Both camera feeds render, controls and output selection work | Unrun |
| Call end/reject/busy/timeout/reconnect | Both devices see the terminal state | SQL and cancellation controller tests passed; real transport unrun |
| Foreground/background/terminated incoming calls | Generic notification, unlock gate, answer/reject where OS permits | Unrun |
| Notifications disabled/muted/locked | No private sender/message content; no alerts when disabled/muted | Implemented; FCM/device unrun |
| Unauthorized third account | Cannot read messages, media, receipts or call token | SQL passed; hosted gateway unrun |
| Group roles/invitations/admin-only/leave | No unauthorized membership or escalation | SQL passed; device unrun |
| Status privacy, views and 24h expiry | Contact-scoped reads; scheduled DB/object cleanup | Implemented; scheduled worker unrun |
| Blocking/reporting | New interactions denied; abuse report retained privately | SQL block check passed; device unrun |
| Logout/account deletion | Local sessions/cache removed; server-owned data cleaned | Implemented; hosted/device unrun |
| Signed release install/start | Valid certificate; same privacy/security behavior with R8 | Blocked: no APK/signing configuration |

Additional release work: load/latency and battery testing, large-group pagination, attachment-transfer UX/accessibility review, service/provider failure injection, OEM background restrictions, TLS/TURN-only connectivity, dedicated security review, verified HTTPS app links, backup/restore behavior and production monitoring. Optional phone OTP, address-book sync, group calls and E2EE are not implemented.

Current source/workflow publication: `codex/phase2-apk-verification` (initial publication `6c3c6af`; follow-up changes are on the same branch). Git read/push succeeded, but GitHub API access is proxy-blocked and no completed workflow/artifact has been inspected. This is not a CI build PASS.

## Firebase SDK configuration check

The Firebase SDK configuration update retained locked `firebase_core` 5.0.0 and `firebase_messaging` 17.0.0; no Analytics package was added. Google Services 4.5.0 resolved from official Google Maven during Android project configuration. The app applies it when the console JSON exists. Initialization now uses native Android resources when Dart Firebase options are absent and reuses an initialized default app. The top-level background entry point uses the same initialization path in its isolate.

Current checks: locked pub resolution PASS; Flutter analysis PASS; **87 Flutter tests PASS, one hosted test skipped**; **34 Python tooling tests PASS**. The configuration tests include raw-JSON CI materialization, matching package/public Dart identifiers, removal of legacy generated XML, refusal to overwrite a different owner console file, and rejection of server credentials. These are local fixture tests, not live Firebase registration or delivery tests.

The requested debug APK build FAILS at official Flutter engine dependencies: `storage.googleapis.com/download.flutter.io` returns HTTP 403. No APK was produced. Native Firebase resource processing with the owner's file is BLOCKED because `android/app/google-services.json` and `FIREBASE_ANDROID_CONFIG` are absent.

Registration code was inspected against installed Messaging 17: it subscribes to `onRegistered` before `register()` (the current APIs replacing deprecated token/refresh APIs), scopes writes to the current authenticated user, and unregisters on logout/disable. Permission requests are opt-in; the manifest declares POST_NOTIFICATIONS and disables auto-registration. Notification content remains generic; actions route through account/device/PIN gates. These observations do not prove token persistence, refresh, background execution or notification delivery on a device.

Owner verification: provide the registered app's console JSON, use connected Supabase build configuration, configure `FIREBASE_SERVICE_ACCOUNT` server-side in Supabase only, install on a Google Play services Android device, sign in/unlock and enable notifications. Verify initial/rotated registration rows without logging token values; send from the deployed backend; test foreground/background/terminated notifications, denied permission, logout and locked notification taps. Force-stopped delivery is subject to Android restrictions.

Firebase follow-up: the owner reports the GitHub Actions secret has been configured. Its value is not available to this cloud machine; GitHub API access returned Forbidden and Git read access failed, so no secret validation against the real file, remote workflow execution or remote artifact existence is claimed. Rechecks passed analysis, 87 Flutter tests (one hosted skip), and 34 tooling tests. New CLI tests exercise the exact CI environment invocation and Android output path, and reject null/empty/malformed console JSON. The local debug build still fails with official Flutter artifact HTTP 403. Push the changes, then select Actions → Android debug APK → Run workflow → mode `connected`; the expected successful artifact is `calculator-messenger-debug-connected`. Connected mode also requires public `SUPABASE_URL`/`SUPABASE_ANON_KEY` repository variables.
