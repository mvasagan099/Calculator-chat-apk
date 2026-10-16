# Local APK optimization — 2026-10-16

## Result

No APK was produced. The under-50,000,000-byte goal is **not yet verified**.
This downloaded folder has no `.git` directory; branch/status cannot be established.
No existing APK was found in this project, so initial size, ARM64/ARM32 size,
percentage reduction and APK SHA-256 are all unavailable.

## Current environment evidence

- Flutter/Dart: unavailable on PATH; no SDK found in the inspected common locations.
- `doctor -v`, locked pub get, analyze, test and release split build were attempted
  through the existing wrapper; each stops at `flutter: not found`.
- Official Flutter artifact host `storage.googleapis.com`: curl fails DNS resolution.
  Download/install could not proceed; no unofficial mirror was substituted.
- JDK 21.0.11 exists at
  `/Users/lakoffice/Library/Java/JavaVirtualMachines/jbr-21.0.11/Contents/Home`.
- Android SDK exists at `/Users/lakoffice/Library/Android/sdk`, including platform 36
  and build-tools 36.0.0. Required NDK 28.2.13676358 is not installed there.
- Gradle wrapper properties specify 9.1.0 and retain a distribution checksum.
  The downloaded source omits `android/gradlew` and the wrapper JAR. Flutter Android
  tooling normally prepares these; actual regeneration is unverified without Flutter.
- ADB 37.0.1 exists but cannot bind its listener (`Operation not permitted`).
  Device availability cannot be determined; no installation or data reset occurred.
- Database tests were attempted; Docker socket access is denied. Deno is unavailable,
  so Edge tests cannot run. Flutter/live provider/device tests remain unverified.
- Owner release signing, connected config and Firebase console JSON are absent.

## Changes and size findings

R8 and resource shrinking were already enabled. Icon tree shaking remains at
Flutter's release default. No application dependencies, assets, security checks,
services or user data were removed. The manifest declares no custom asset/font
bundles in pubspec. The existing SQLite test dependency constraint already avoids
the second native-asset SQLite engine described by the project's earlier report.
LiveKit and WebRTC are both used directly by calling code; removing either would
be unsafe. Their actual native contribution requires built APK bytes. Flutter
engine/AOT, WebRTC, Firebase/DEX and media sizes cannot be measured from this source
download alone. No duplicate packaged library or unused resource removal is claimed.

Added `scripts/build-optimized-apks.sh`: requires connected public configuration,
Firebase console JSON and owner signing, runs checks, then requests ARM64/ARM32
release splits. Actual ABI support remains dependent on SDK/plugin compilation.
Each artifact is inspected with existing Android signature/package/secret tooling,
then checked for one expected ABI, Flutter engine/AOT presence and a strict decimal
50 MB ceiling. The size report records actual bytes, compressed groups, largest
25 entries, ZIP overhead and SHA-256. It does not certify provider behavior.

Updated APK hashing to support this laptop's Python (streaming SHA-256 rather
than Python 3.11-only `hashlib.file_digest`). Added two size accounting tests.

## Resume with available toolchain and owner inputs

Install the project's pinned Flutter 3.44.0 from the official Flutter distribution,
retain `pubspec.lock`, and configure Android SDK/NDK through Android Studio. Do not
upgrade project dependencies to compensate for missing tools. Set Flutter on PATH
and JAVA_HOME to the JDK above. Flutter size analysis can then be run separately
for ARM64 using `--target-platform android-arm64 --analyze-size` with the same
connected public defines and owner signing. Save that baseline before considering
additional dependency changes. A universal release baseline, if needed, must use
the same source/config/signer for a meaningful split-size comparison.

Provide ignored `config/local.json` with the real public Supabase URL and anon or
publishable key (`LOCAL_UI_PREVIEW: false`). Provide matching Android console
`android/app/google-services.json`; the preparation script validates Firebase IDs
against package `app.calculatorspace.calculator_messenger`. LiveKit server secrets
and Firebase service accounts stay on the backend. No migrations were deployed.

Reuse an existing owner keystore to preserve update compatibility. If none exists,
create one locally with JDK keytool's interactive password prompts, outside the
repository, and keep a private backup:

```sh
keytool -genkeypair -v -keystore /PRIVATE/OWNER/PATH/calculator-release.jks \
  -alias calculator-release -keyalg RSA -keysize 3072 -validity 10000
```

Replace that placeholder with an owner-controlled private directory. Configure
ignored `android/key.properties` locally with `storeFile` (absolute path),
`storePassword`, `keyAlias`, `keyPassword`; restrict permissions to the owner.
Never put passwords in chat, command arguments or Git. Obtain the public SHA-256
certificate fingerprint using `keytool -list -v -keystore ...` (interactive prompt).
Then run from the project root:

```sh
export ANDROID_HOME=/Users/lakoffice/Library/Android/sdk
export ANDROID_CERT_SHA256=OWNER_PUBLIC_CERTIFICATE_SHA256
bash scripts/build-optimized-apks.sh config/local.json
```

Expected outputs **after success**, not existing artifacts:

- `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`
- `build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk`
- Adjacent `.apk.sha256` files and `build/apk-evidence/<abi>/size.json`.

Check `apksigner verify --verbose --print-certs APK`, then use `adb install -r APK`
on an authorized phone. Stop on signer mismatch; do not uninstall or clear data.
Follow `DEVICE_ACCEPTANCE.md` for calculator/PIN, authentication, group/media,
offline retry, LiveKit calls, notification privacy and lifecycle checks. Measure
startup and memory on hardware. No live feature or device test is claimed here.
