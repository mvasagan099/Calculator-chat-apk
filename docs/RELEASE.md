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

Never commit this file, the keystore or passwords. Release CI would need secure secret/file injection; the prepared workflow builds debug-signed APKs for internal testing only. It does not build a signed release. The Gradle release configuration intentionally has **no debug-signing fallback**. An unsigned APK is not installable until signed.

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

After publishing the source/workflow to the selected repository and enabling Actions:

1. A push/PR builds `preview` automatically. For an explicit run open **Actions → Android debug APK → Run workflow**, select the source branch and mode. Manual dispatch requires the workflow to be present on the repository's default branch.
2. For `connected`, set repository **variables** `SUPABASE_URL` and `SUPABASE_ANON_KEY` to real public identifiers. To include Firebase, set `FIREBASE_ANDROID_CONFIG` to the public Android console JSON. Optional separate Firebase public variables must match that JSON. Never add service-role keys, test passwords, LiveKit secrets or service-account JSON to these variables.
3. A successful run uploads exactly `calculator-messenger-debug-preview` or `calculator-messenger-debug-connected`. These contain `app-debug.apk`, its SHA-256 file, Android package/API metadata and signature details. The APK upload step runs only after all artifact checks succeed; missing files are errors. Diagnostics use `calculator-messenger-build-logs-RUN_ID`, retained for 14 days even on build failure where logs exist.
4. Download from the completed run's **Artifacts** section. With authenticated GitHub CLI/API access:

   ```sh
   gh run list --repo mvasagan099/Calculator-chat-apk --workflow android-debug.yml
   gh run download RUN_ID --repo mvasagan099/Calculator-chat-apk \
     --name calculator-messenger-debug-preview --dir downloaded-apk
   cd downloaded-apk
   sha256sum -c app-debug.apk.sha256
   adb install -r app-debug.apk
   ```

   Use the connected artifact name for a connected run. No specific run ID, completed artifact, checksum or download URL is invented in this report.

`verify-apk.py` checks a real, nonempty ZIP/APK with Android apksigner/aapt2, exact package ID, minimum API 29, launchable activity, private-file exclusions and known PEM/Supabase secret formats. This pattern scan plus an allowlisted public input config is limited evidence, not a comprehensive forensic guarantee. Actual launch, microphone/camera, biometric, notifications and provider delivery require a device.

Debug keys are generated by Android for internal testing, not a production identity. A new ephemeral CI runner may generate a different debug certificate; replacing an earlier differently signed APK can require uninstalling it, which removes local app data. Keep your own stable signing identity for releases. Do not treat a preview APK as connected messaging proof.
