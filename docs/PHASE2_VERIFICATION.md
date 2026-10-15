# Phase 2 verification report

Recorded 2026-10-15. The repository was preserved in its existing checkout, with no additional worktree or application dependency upgrade.

## Completed work

- Inspected all seven migrations, six Edge Function entry points, Android configuration, notification/call code and setup/security documentation.
- Rechecked the official Flutter SDK tag: 3.44.0 resolves to `559ffa3f75e7402d65a8def9c28389a9b2e6fe42`, matching the retained SDK. Full JDK 21, Android SDK/build-tools 36, NDK 28.2 and CMake are present. Android licenses are accepted.
- Added `android-debug.yml`: exact official Flutter Git checkout, pinned Actions, locked dependencies, analysis/tests, signed debug APK, signature/package/minimum-API inspection, known-secret-format scanning, SHA-256 and diagnostics artifacts. Actionlint passed. This does not claim a workflow run or APK exists.
- Added public-config validation and matching native Firebase resource generation from the Firebase Android console configuration. This supports native process startup before Dart initialization; package/project/sender/app identifiers must agree. Automatic FCM registration is disabled until explicit registration. No Firebase project was fabricated.
- Hardened notification registration cancellation, generic routing payloads and account-owner/PIN gates. Added client and server notification privacy tests.
- Added real-provider staging acceptance with explicit target/write consent, sanitized PASS/FAIL/BLOCKED/NOT TESTED output, valid image/audio fixtures and best-effort cleanup. Added read-only remote-schema preflight.

## Artifact access diagnosis

The configured HTTPS proxy returns **HTTP 403 on CONNECT** to `storage.googleapis.com`; there is no TLS tunnel, certificate exchange or Google-origin response. This is a runtime egress denial, not a Supabase error, missing Android SDK, dependency-version conflict or TLS-validation problem. The internal rule/organization setting that rejects the tunnel is not visible here.

The saved environment draft already included the official Flutter host. Draft persistence does not apply runtime settings or publish the environment. Existing Java proxy/trust configuration was reused; TLS and checksums stayed enabled. `pub get --enforce-lockfile` and Android precache passed using retained artifacts, but Gradle still needs official Maven coordinates unavailable from the current cache. Repacking cached binaries into invented Maven packages was not used.

A direct check of `dl.google.com` succeeds; the authoritative Flutter embedding Maven URL and `api.github.com` fail before TLS. Evidence: [network responses](phase2-network-results.json), [doctor](phase2-doctor.txt), [debug build](phase2-debug-build.txt). Git read access works through the platform Git proxy; this does not prove GitHub API or workflow write access.

## Current results

| Check | Status | Evidence / limit |
| --- | --- | --- |
| Flutter dependency lockfile install | PASS | phase2-pub-get.txt; versions retained |
| Android artifact precache | PASS | Cached artifacts; does not prove Maven access |
| Flutter analysis | PASS | No issues; phase2-analysis.txt |
| Flutter unit/widget tests | PASS | 42 passed; one hosted test skipped |
| Edge/helper type checking | PASS | Six entry points plus hosted runner |
| Edge security/privacy tests | PASS | Five tests; no real FCM delivery |
| PostgreSQL migration/security checks | PASS | Seven migrations, four real PostgreSQL suites |
| Public build-config tests | PASS | 11 tests; no provider credentials verified |
| Workflow lint | PASS | actionlint 1.7.7; workflow not executed here |
| Local debug APK | BLOCKED | Official Flutter Maven host proxy CONNECT 403 |
| Signed release APK | BLOCKED | No private keystore/config; not attempted this phase |
| APK file size, package, signature, checksum | BLOCKED | No APK exists to inspect locally |
| Supabase deployment | BLOCKED | No confirmed target, URL/key, remote history or schema access |
| Firebase deployment/delivery | BLOCKED | No matching Android console config, project, server account or device registration |
| LiveKit media | BLOCKED | No provider endpoint/server credentials or real participants |
| Physical Android install/launch | BLOCKED | `adb devices -l` lists no devices |
| Recent-app masking, biometrics, OS notification states | NOT TESTED | Native/device verification required |

The 16 hosted scenarios are individually BLOCKED in [hosted-results.json](hosted-results.json). Flutter/SQL/helper tests are separate evidence and cannot turn a hosted/device scenario into PASS. No remote migrations, functions, provider infrastructure or signing secrets were created/deployed.

## Owner steps

1. Review/save the environment's network settings so the saved official Flutter domains become effective in the runtime. Permit `api.github.com` for authenticated workflow status/artifact operations. A new task/publication may be needed; recheck the actual CONNECT response before another build.
2. Publish the source/workflow to the authorized GitHub repository, enable Actions if needed and run **Android debug APK**. Automatic push/PR builds use local preview mode. The exact success artifact is `calculator-messenger-debug-preview`; manual connected builds use `calculator-messenger-debug-connected`. Logs use `calculator-messenger-build-logs-RUN_ID`. RELEASE.md has the download procedure. No artifact/run link is invented.
3. Create/confirm a dedicated Supabase staging project, review its remote schema/history before migration, then deploy the existing backend using DEPLOYMENT.md. Add only public client identifiers to build config.
4. Register the exact Firebase Android package, provide its console `google-services.json` as public config input, and store the FCM service account only in Supabase. Configure LiveKit URL/key/secret and signed webhook on the server, plus Cron/Vault workers.
5. Provide two disposable verified staging accounts and run HOSTED_TESTS.md. Connect two Android devices, install the verified debug APK, and execute the privacy/messaging/call/notification checklist. Record actual results.
6. Supply a private release keystore through secure local/CI signing configuration only when ready for signed release validation. No production keystore or password was invented.
