# Android release

The Android app ID is `app.calculatorspace.calculator_messenger`; launcher label is **Calculator** with an original vector calculator icon. Minimum Android 10/API 29, compile/target SDK from Flutter 3.44.0 (36), JDK 21 and the Gradle wrapper are configured. The wrapper distribution has its official SHA-256 pinned. Flutter's template compatibility flags retain legacy Kotlin support for plugins that have not migrated to AGP's built-in Kotlin.

## Phase 1 local build

The default build runs the labelled, read-only local UI preview. It needs no service credentials:

```sh
./scripts/flutterw build apk --debug
./scripts/flutterw build apk --release
```

To build connected mode, use an ignored configuration file containing `LOCAL_UI_PREVIEW: false` and real public provider identifiers. Its account authentication and separate account PIN are required. Never ship samples as real messages.

## Signing

Create a private release keystore using Android Studio or `keytool`. Keep it outside the repository and back it up securely. Create ignored `android/key.properties` on the build machine:

```properties
storeFile=/absolute/private/path/release.jks
storePassword=YOUR_LOCAL_SECRET
keyAlias=YOUR_ALIAS
keyPassword=YOUR_LOCAL_SECRET
```

Never commit this file, the keystore or passwords. The existing debug workflow remains for internal tests. Phase 6 also prepares an explicitly manual, protected workflow for owner-signed development APK/AAB artifacts; no successful run or owner key exists here. The Gradle release configuration intentionally has **no debug-signing fallback**. Release tasks now reject missing/incomplete signing configuration rather than producing an unsigned artifact.

```sh
./scripts/flutterw pub get --enforce-lockfile
./scripts/flutterw analyze
./scripts/flutterw test
./scripts/flutterw build apk --release --dart-define-from-file=config/local.json
```

Check `build/app/outputs/flutter-apk` and the underlying Android outputs. With valid signing configuration, Flutter normally writes `build/app/outputs/flutter-apk/app-release.apk`. Verify the actual artifact and certificate rather than assuming a filename proves signing:

```sh
apksigner verify --verbose --print-certs /path/to/the/release.apk
adb install -r /path/to/the/release.apk
```

For local evaluation use `flutter build apk --debug` to create a debug-signed installable APK. That is not a production signing identity. Do not distribute a blank-configuration APK as a functioning messenger: supply the public project configuration and deploy all backend services first.

Inspect merged permissions and foreground service declarations, disable Android backups (already configured), verify FLAG_SECURE/recent-app behavior, confirm deep-link ownership and run every physical-device scenario in TESTING.md. Verify minified release builds specifically: a debug-only test does not validate R8, resource shrinking, release permissions or background execution.

## Current build blocker

Both Phase 1 debug and release builds were attempted with the full Android SDK, NDK and a checksum-verified Temurin JDK 21.0.12.1. They failed downloading `io.flutter:flutter_embedding_debug` / `io.flutter:flutter_embedding_release` from `storage.googleapis.com/download.flutter.io` with HTTP 403. Google Maven also returned transient 503 errors. Flutter's automatic retry did not resolve the policy block. No APK was produced, no release certificate was supplied, and no APK installation was tested.

After applying the saved network addition in environment settings, retry the command above. Do not disable TLS, use untrusted artifacts or alter expected checksums to make it pass. The exact build log may also mention `jitpack.io` because a dependency includes that fallback repository; the Flutter artifact's authoritative host is `storage.googleapis.com`.

Recorded Phase 1 logs: [debug](phase1-debug-build.txt), [release](phase1-release-build.txt). Neither attempt reached successful Android compilation.

## GitHub Actions fallback

The workflow file is `.github/workflows/android-debug.yml`, displayed as **Android debug APK**. It uses pinned checkout/Java/Android/upload Actions and clones the official Flutter 3.44.0 tag, requiring commit `559ffa3f75e7402d65a8def9c28389a9b2e6fe42`. No application dependency upgrades or untrusted mirrors are used.

The source/workflow is published on `codex/phase2-apk-verification`. After enabling Actions if needed:

1. A push/PR builds `preview` automatically. For an explicit run open **Actions → Android debug APK → Run workflow**, select the source branch and mode. Manual dispatch requires the workflow to be present on the repository's default branch.
2. For `connected`, set repository **variables** `SUPABASE_URL` and `SUPABASE_ANON_KEY` to real public identifiers. To include Firebase, set the GitHub Actions **secret** `FIREBASE_ANDROID_CONFIG` to the complete raw Android console JSON (not base64); the existing repository-variable fallback remains supported. The preparer validates the package, writes ignored `android/app/google-services.json`, and Google Services plugin 4.5.0 generates native resources. Optional separate Firebase public variables must match that JSON. Never add service-role keys, test passwords, LiveKit secrets or service-account JSON to these variables.
3. A successful run uploads exactly `calculator-messenger-debug-preview` or `calculator-messenger-debug-connected`. These contain `app-debug.apk`, its SHA-256 file, Android package/API metadata and signature details. The APK upload step runs only after all artifact checks succeed; missing files are errors. Diagnostics use `calculator-messenger-build-logs-RUN_ID`, retained for 14 days even on build failure where logs exist.
4. Download from the completed run's **Artifacts** section. With authenticated GitHub CLI/API access:

   ```sh
   gh run list --repo mvasagan099/Calculator-chat-apk --workflow android-debug.yml --branch codex/phase2-apk-verification
   gh run download RUN_ID --repo mvasagan099/Calculator-chat-apk \
     --name calculator-messenger-debug-preview --dir downloaded-apk
   cd downloaded-apk
   sha256sum -c app-debug.apk.sha256
   adb install -r app-debug.apk
   ```

   Use the connected artifact name for a connected run. No specific run ID, completed artifact, checksum or download URL is invented in this report.

`verify-apk.py` checks a real, nonempty ZIP/APK with Android apksigner/aapt2, exact package ID, minimum API 29, launchable activity, private-file exclusions and known PEM/Supabase secret formats. This pattern scan plus an allowlisted public input config is limited evidence, not a comprehensive forensic guarantee. Actual launch, microphone/camera, biometric, notifications and provider delivery require a device.

Debug keys are generated by Android for internal testing, not a production identity. A new ephemeral CI runner may generate a different debug certificate; replacing an earlier differently signed APK can require uninstalling it, which removes local app data. Keep your own stable signing identity for releases. Do not treat a preview APK as connected messaging proof.

## Phase 3 build result

The exact debug command with ignored `config/local.json` was retried. That generated file contains preview mode only, without provider credentials. The command exited 1 fetching the official engine embedding Maven dependency with proxy HTTP 403; no APK or SHA-256 exists. [Build log](phase3-debug-build.txt), [network evidence](phase3-network.txt), [acceptance matrix](PHASE3_BETA_READINESS.md#acceptance-matrix). Android licenses/toolchain and cached precache pass, but those do not satisfy the missing Maven coordinates.

Release signing remains absent; no signed release was attempted. `adb devices -l` is empty, so install/start/permissions/biometrics/foreground services remain untested. Existing CI artifact names and download instructions above still apply only after a successful workflow. GitHub API access remains denied, so no run or APK artifact has been inspected from this instance. Native location/Bluetooth changes must pass that build and device validation before beta distribution.

## Phase 4 outcome

The same debug build command with ignored preview-only `config/local.json` was attempted again and failed at the official Flutter embedding Maven dependency with HTTP 403. [Current log](phase4-debug-build.txt). No APK, checksum, signature or installation result exists; there is no attached Android device or private release keystore. GitHub API access remains denied, so a pushed workflow is not a verified build/artifact.

The native Signal test JARs live only in the toolchain/prototype cache; they are not Android dependencies and do not turn the APK into an E2EE messenger. The existing trusted APK workflow is preserved, and backend CI adds a separate pinned-JDK native protocol probe. Privacy/device features require the ten-migration/eight-function staging rollout before a connected build can be tested. Refer to [Phase 4 feature status and limitations](PHASE4_SECURITY.md) before beta distribution.

## Phase 5 build result

The current debug command with ignored preview-only `config/local.json` exited 1 resolving the official Flutter embedding Maven dependency (HTTP 403). [Log](phase5-debug-build.txt). No APK exists; no file size/checksum/signature/install/launch success is claimed. Release signing is absent. GitHub Actions API access is unavailable, so no completed workflow or artifact has been inspected. The existing trusted workflow/artifact names above are preserved for owner/CI execution.

This phase adds native MediaProjection/FGS readiness and notification actions that require actual Android compilation and Android 10/13/14+ lifecycle tests. Client dependency versions are unchanged: the existing locked WebRTC package is now a direct dependency for its documented permission helper. Complete the coordinated 11-migration/nine-function staging rollout and [calling acceptance matrix](PHASE5_CALLS.md) before beta distribution. A compiled preview APK alone would not verify Supabase messaging, calling, notifications or screen sharing.

## Phase 6 signing and AAB preparation

Current result: debug dependency resolution is blocked by official Flutter proxy CONNECT 403; no debug APK, owner-signed APK, AAB or checksum exists. Signing preflight exits 2 without creating private files because no owner inputs are supplied. [Audit/gates](PHASE6_RELEASE.md), [current build log](phase6-debug-build.txt).

The source retains package `app.calculatorspace.calculator_messenger`, min API 29, target API 36 and `1.0.0+1`. Confirm actual merged metadata and monotonically increasing version code relative to the real Play listing before distribution. Do not change package/signing identity to bypass update errors or automatically uninstall existing data.

For local owner signing use the existing private `android/key.properties` format above and your own backed-up keystore. The helper/CI never generates an app key. With all prerequisites configured:

```sh
./scripts/flutterw build apk --release --dart-define-from-file=config/local.json
./scripts/flutterw build appbundle --release --dart-define-from-file=config/local.json
python3 scripts/verify-apk.py build/app/outputs/flutter-apk/app-release.apk \
  --android-sdk "$ANDROID_HOME" --variant release \
  --expected-cert-sha256 OWNER_CERTIFICATE_SHA256 --output-dir build-evidence/signed
python3 scripts/verify-aab.py build/app/outputs/bundle/release/app-release.aab \
  --expected-cert-sha256 OWNER_CERTIFICATE_SHA256 --output-dir build-evidence/signed
```

The APK inspector calls real `apksigner`/`aapt2`, pins the release certificate and writes `app-release.apk.sha256`. Debug output remains `app-debug.apk.sha256`. The AAB inspector uses standard JDK JAR signature verification for every content entry, pins the same certificate and writes `app-release.aab.sha256`. Its structured report explicitly does **not** verify AAB manifest package/API, Play acceptance or installation. Installable splits/universal APKs must be generated and inspected with a trusted official [bundletool](https://developer.android.com/tools/bundletool); preserve artifact provenance/checksums and do not use an untrusted downloaded JAR:

```sh
java -jar /private/verified-tools/bundletool-all.jar validate --bundle=build/app/outputs/bundle/release/app-release.aab
java -jar /private/verified-tools/bundletool-all.jar dump manifest --bundle=build/app/outputs/bundle/release/app-release.aab
```

Inspect package/SDK/version in that output, then follow the official device-targeted `build-apks` / `install-apks` procedure with protected signing inputs. Avoid passwords in CLI/history/logs; use bundletool's supported password-file inputs with private permissions. No bundletool binary or generated APK set was fabricated in this environment.

### Protected signed-development CI

Workflow: `.github/workflows/android-signed-development.yml`, **Signed Android development artifacts**. It is manual only, rejects unprotected source, and requires its explicit development-only acknowledgement. The owner must first configure an `android-release` environment with required reviewers and deployment branches limited to reviewed protected source, plus required backend/security checks. YAML cannot establish those account settings. Do not make signing secrets available to fork PRs/unreviewed source.

Environment **secrets**: `ANDROID_RELEASE_KEYSTORE_B64` (the existing owner keystore encoded privately), `ANDROID_KEY_ALIAS`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_PASSWORD`. Environment **variable**: `ANDROID_CERT_SHA256` (public signing-certificate SHA-256, not the APK hash). Set connected public repository/environment variables `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and matching `FIREBASE_ANDROID_CONFIG` when notifications are included. Server service-role/LiveKit/Firebase service-account secrets never belong in this workflow or Flutter config. Use secret settings, never chat/Git or command-line password arguments.

The helper refuses existing owner files, writes generated signing files privately in the ephemeral runner, checks the actual certificate with keytool before build, and removes only its recorded files in the always-run cleanup step. Do not export private signing files, whole workspaces, heaps or process environments as artifacts. Android/JAR fixture unit tests generate temporary **test** keys only; these are deleted and never represent the app's release identity.

After the workflow is available on the repository's actual default branch, open Actions → Signed Android development artifacts → Run workflow, select the reviewed protected ref and acknowledge development-only status. A successful run uploads `calculator-messenger-signed-development` for seven days; logs use `calculator-messenger-signed-build-logs-RUN_ID`. No Play/GitHub Release publishing step exists. Artifact visibility follows repository access; use an appropriately private CI repository/environment for confidential distribution. Owner-signing setup, actual workflow execution and all resulting artifacts remain unverified here.

```sh
gh run list --repo mvasagan099/Calculator-chat-apk --workflow android-signed-development.yml
gh run download RUN_ID --repo mvasagan099/Calculator-chat-apk \
  --name calculator-messenger-signed-development --dir downloaded-signed
cd downloaded-signed
sha256sum -c app-release.apk.sha256
sha256sum -c app-release.aab.sha256
apksigner verify --verbose --print-certs app-release.apk
adb -s PHONE_A_SERIAL install -r app-release.apk
```

These are future download/install instructions, not existing paths/artifacts. Check the owner certificate before installation. Git works in this environment but the Actions API is CONNECT-blocked, so no run ID, checksum, artifact URL or installation result is invented. Follow [the phone test plan](DEVICE_ACCEPTANCE.md) and [transparent store disclosure review](STORE_REVIEW.md) before any beta/production claim. An inspected signed artifact alone does not satisfy hosted/media/privacy/stability gates.

## Phase 7 preview versus connected artifacts

The owner confirms a successful preview APK build/static inspection and installation. Historical “no APK” entries describe earlier local attempts, not the current owner report. No run ID/hash or downloaded APK could be independently inspected here because Actions API access returns Forbidden. The connected artifact remains unverified: select the current branch and connected mode in the debug workflow after setting the real public Supabase pair and raw Firebase JSON secret. Expected artifact: `calculator-messenger-debug-connected`. Preserve the existing preview installation/data on signing mismatch; use its original signer or an owner-approved fresh disposable device/profile. Never silently uninstall/clear data. See [PHASE7_ACTIVATION.md](PHASE7_ACTIVATION.md).
