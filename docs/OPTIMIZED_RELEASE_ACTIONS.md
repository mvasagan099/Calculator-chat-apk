# Optimized release APK workflow

Prepared locally on 2026-10-16. No APK has been produced. The shell clone failed
DNS resolution, so publication uses the connected GitHub Git-data API to preserve
the existing commit ancestry. The target branch was fetched at
`7b66576a4b27378d7fb311f4f9fba08db789e551`, tree
`2f44df6cc45d1a8f8333e77bfbac9cd9146d63e6`. All 298 tracked source files were
compared using Git blob hashes: 297 identical, only `scripts/verify-apk.py` changed
(the reviewed Python compatibility fix). New optimization files are added separately.
The new commit uses this existing tree and parent with a non-force, expected-head
ref update; unrelated files and recent remote work are preserved.

## Prepared change

New workflow: `.github/workflows/android-optimized-release.yml`.
Existing debug, signed-development and check workflows are unchanged.

The workflow uses the existing pinned Flutter 3.44.0 installer, JDK 21, Android SDK
36/build-tools 36.0.0, NDK 28.2.13676358 and CMake 3.22.1. Locked dependency
resolution, analysis and Flutter/tooling tests run before signing materialization.
Separate ARM64 and ARM32 jobs compile one architecture each; matrix fail-fast is
disabled. Backend SQL authorization/concurrency, Edge tests and native PIN/Signal
prototype tests must pass first. These use disposable CI resources, not production.

Release Gradle configuration already enables R8/resource shrinking. Flutter's
release icon tree shaking stays enabled. All app dependencies and features remain
intact. The standalone local build script from the previous task is preserved.

Each release must pass owner-certificate, package/API, known-private-credential,
single-ABI, Flutter engine/AOT and strict `< 50,000,000` byte checks. This is a
known-format credential scan, not proof that every possible secret is absent.
Only passing artifacts are uploaded as installable deliverables. An oversized APK
fails its job but its `size.json` diagnostics retain the largest 25 ZIP entries,
compressed byte totals, ZIP overhead and actual APK size/hash. This can guide the
next optimization without deleting WebRTC or other required functionality.

The workflow is manual-only and uses a read-only GitHub token. It requires the
same protected-ref/development acknowledgement gate as the existing signing
workflow. Configure the `android-release` environment with required reviewers and
deployment branches restricted to reviewed protected source. It does not publish
to Play, deploy services or certify production readiness. Native Signal prototype
tests do not make application E2EE operational.

## Owner configuration

Repository: `mvasagan099/Calculator-chat-apk`.
Under Settings → Environments → `android-release`, configure signing secrets:

| Secret | Value |
| --- | --- |
| `ANDROID_RELEASE_KEYSTORE_B64` | One-line base64 encoding of the existing owner keystore |
| `ANDROID_KEY_ALIAS` | Keystore alias |
| `ANDROID_STORE_PASSWORD` | Store password |
| `ANDROID_KEY_PASSWORD` | Private key password |

Add environment variable `ANDROID_CERT_SHA256`: the certificate SHA-256, not an
APK checksum. The helper verifies it against the supplied keystore before build,
creates private temporary files and cleans up only files it created. No debug
signing fallback exists. GitHub secret presence was not inspected in this session.

Reuse your current keystore if an app identity already exists. For a new identity,
run locally in an owner-controlled directory outside Git:

```sh
keytool -genkeypair -v -keystore /PRIVATE/OWNER/PATH/calculator-release.jks \
  -alias calculator-release -keyalg RSA -keysize 3072 -validity 10000
keytool -list -v -keystore /PRIVATE/OWNER/PATH/calculator-release.jks \
  -alias calculator-release
```

Use interactive password prompts and back up the key securely. PKCS12 stores
normally use the same store/key password. Encode the keystore locally as one-line
base64, paste it directly into the GitHub secret editor, and never paste it into
chat or commit it. Base64 is not encryption. Restrict/delete any temporary encoded
copy. Do not create a new key to bypass an installed app's signer mismatch.

Connected repository/environment variables `SUPABASE_URL` and
`SUPABASE_ANON_KEY` are used, with same-named GitHub Secrets supported as fallback.
`FIREBASE_ANDROID_CONFIG` uses the existing secret, then variable fallback. It must
be complete raw Android console `google-services.json`, not base64 or a Firebase
service account. Firebase is mandatory in this workflow. The existing validator
checks the public key/config and package identity
`app.calculatorspace.calculator_messenger`. LiveKit secrets remain backend-only.

## Run after approved publication

The repository metadata confirms `codex/phase2-apk-verification` is already the
default branch, so publishing here registers the dispatch workflow without merging
into main. The branch API currently reports `protected: false`: the existing
protected-ref signing gate will deliberately reject it until the owner configures
branch protection/rules. No security settings were changed during publication.
Secret/environment configuration could not be inspected through the available
connector; browser access also failed before opening the settings page. Their
presence is unverified, not presumed absent. Confirm the signing environment and
public configuration above before dispatch.

Use a reviewed protected ref with the required secrets available.
Open Actions → **Optimized signed Android release APKs** → Run workflow; select the
ref and acknowledge the stated development/device-test limitations.

Expected successful artifact names (not existing downloads):

- `calculator-messenger-release-arm64-v8a-RUN_ID`
- `calculator-messenger-release-armeabi-v7a-RUN_ID`

Each contains its architecture-specific APK, adjacent checksum and inspection
evidence. Evidence paths inside upload ZIPs retain their build-directory hierarchy.
Diagnostics: `calculator-messenger-release-diagnostics-ABI-RUN_ID` and
`calculator-messenger-release-security-RUN_ID`. Retention is seven days. Normal
build outputs remain `build/app/outputs/flutter-apk/app-ABI-release.apk` in CI.

## Verification in this session

- 39 Python tooling tests passed, including strict size-boundary/mixed-ABI tests.
- Independent desktop JCA/PIN compatibility vectors passed (600,000 iterations).
- Workflow YAML parsing, manual-only trigger, read-only token and all inline Bash
  syntax checks passed. Actionlint is unavailable; Actions execution remains needed.
- Signing preflight rejected absent credentials as expected; no owner files changed.
- JDK 21 and SDK/build-tools 36 exist locally. Flutter/NDK remain unavailable;
  a single official-download probe failed DNS. No repeated download retries.
- Flutter compilation/tests, SQL/Edge/native Signal tests and real device/provider
  verification have not run here. Local Docker/ADB restrictions were established
  in the preceding task. CI is configured to run the available automated suites.

ARM64/ARM32 bytes, reduction, largest actual native contributors, APK SHA-256 and
signature verification remain **unavailable until a real build completes**.
No APK is represented as produced, installable or under target. Missing remote
configuration, signing secrets, ref protections and actual ABI support will be
determined by the workflow rather than assumed. Phone acceptance remains separate;
use `DEVICE_ACCEPTANCE.md` and preserve installed app data on signer mismatch.
