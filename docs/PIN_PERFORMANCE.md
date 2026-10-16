# PIN responsiveness and performance evidence

This change preserves PBKDF2-HMAC-SHA256, the **600,000-iteration default**, 256-bit output, random 32-byte salt, v1 storage keys/JSON and persistent attempt throttling. Stored iteration counts are honored. No PIN, verifier, user data or Keystore configuration is reset. Backend, Firebase, LiveKit and the existing debug workflow are unchanged.

## Findings and measured scope

The old cryptography 2.9.0 Dart PBKDF2 implementation yields for 1 ms every 2,000 iterations. At 600,000 iterations there are 299 explicit waits, even though the app already runs it in a dedicated isolate. The calculator also ignored input until this completed, rebuilt its whole keypad on every key, and rewrote the secure record on every successful PIN, including already-clear throttle state.

Three synthetic **desktop Dart JIT isolate** runs with the same library, iterations, key length, input and salt produced:

| Stage, mean milliseconds | Previous library defaults | Same Dart library, no worker yields |
| --- | ---: | ---: |
| PBKDF2 wall time | 2229.139 | 1802.444 |
| Isolate startup/input transfer to worker entry | 1.689 | 0.488 |
| Total isolate operation | 2231.127 | 1803.114 |
| Actual Android secure-storage read | NOT MEASURED | NOT MEASURED |
| Actual Android secure-storage write | NOT MEASURED | NOT MEASURED |
| Navigation/first frame | NOT MEASURED | NOT MEASURED |
| Android end-to-end unlock | NOT MEASURED | NOT MEASURED |

The CPU benchmark demonstrates avoidable waits and expensive Dart derivation on this host; isolate startup is small here. The measured derivation gap is about 19% across these samples, not an Android improvement guarantee. A separate warmed desktop JDK run of the production JCA wrapper averaged **134.936 ms** for derivation (three samples). JIT Dart versus warmed JDK/provider figures are not an apples-to-apples mobile comparison. First-use provider/thread setup and Android OEM hardware may differ substantially. The owner's exact device delay and its stage breakdown remain unmeasured.

[Raw durations](pin-performance-desktop.json) contain only synthetic benchmark measurements. No production PINs/accounts/Keystore records are read by these tools.

## Implementation

- Android uses `SecretKeyFactory` / `PBKDF2WithHmacSHA256` / `PBEKeySpec` on a single native executor, not the Android UI thread. This is the platform's standard PBKDF2 implementation, not a new cryptographic algorithm. Numeric PIN encoding matches the v1 verifier. Temporary Java password arrays/spec are cleared best effort; immutable Dart/Java strings and OS memory are not guaranteed erasable.
- Desktop/other platforms and nonstandard legacy salts/wrong-input formats retain the existing cryptography library inside `Isolate.run`, disabling only the unnecessary yield timer. The algorithm, HMAC, work factor and output are unchanged. Android native failures fail closed instead of silently reducing parameters/resetting the PIN. Baseline/optimized Dart variants are available for profile comparisons.
- Secure storage is read on every verification; no plaintext PIN or cached verifier bypass is added. Clean success skips only a write when **both** `failures` and `until` are already zero. Wrong attempts persist, lockouts survive restart, and successful dirty resets must persist before verification returns true. A failed reset write still rejects unlock.
- Equals displays ordinary arithmetic output immediately. No spinner, secret-authentication text, success/failure decoration or private screen is shown before authorization. A display-only notifier avoids rebuilding the keypad. Continuing to type cancels the pending unlock epoch while preserving the completed attempt's accounting. Leaving the calculator, backgrounding or relocking also prevents late results from opening private content. Existing Auth/device/PIN routes and preview/account namespaces remain intact.

## Optional privacy-safe profiling

Set `PIN_UNLOCK_PROFILING=true` in a developer debug/profile build. It defaults off, and release builds cannot enable output. Every equals operation uses the same instrumentation path. Output is a single `CALCULATOR_TIMING_US` JSON line with fixed duration fields only:

| Field | Meaning |
| --- | --- |
| `storageRead_us` | Secure-storage read including plugin/Keystore/I/O overhead |
| `derivation_us` | PBKDF2 execution wall time in the selected worker/provider |
| `isolateStartup_us` | Isolate submission to worker entry, including input transfer; zero/not applicable on native backend |
| `nativeQueue_us` | Native dispatch to worker entry, including thread startup/queue; zero on Dart backend |
| `transport_us` | Remaining channel/isolate response transfer and scheduling overhead |
| `storageWrite_us` | Persisted throttle/reset write; zero when correctly skipped |
| `navigation_us` | Route request to next Flutter post-frame callback; not full transition/raster completion |
| `total_us` | Equals operation to completion or next post-navigation callback; direct vault callers measure verification only |

No PINs, salts, derived bytes, storage contents/keys, account IDs, routes or verification outcomes enter these metrics. There is no server telemetry/upload. DevTools also has generic storage timing spans. Timings are noisy wall-clock observations, not crypto-strength or OS privacy proofs. Derivation/worker/transport fields partition one operation; comparisons/JSON/route overhead mean the stages need not exactly sum to total. Wrong PIN/lockout/non-candidate calculations have no navigation stage.

Capture only filtered developer timing lines, not full system logs:

```sh
adb logcat -s flutter:I | rg CALCULATOR_TIMING_US
```

Do not publish a full logcat, screenshots of private content, test credentials or device identifiers. Profile only with owner consent on disposable test data.

## Optional ARM64 profile workflow

The existing `android-debug.yml` is byte-for-byte preserved. New `android-pin-profile.yml` is **manual only**, with the same pinned toolchain/Android SDK fix/disk cleanup, lockfile analysis/tests, public-config validation and APK signature/package/SDK/known-secret checks.

If GitHub does not list this new manual workflow yet, its workflow file may need to be present on the default branch before dispatch becomes available; no default-branch merge is performed automatically. Once available, select branch `codex/phase2-apk-verification`, mode `preview` (or `connected` with existing provider configuration), and implementation:

- `native`: Android JCA (default).
- `dart-isolate`: same library with worker yields removed.
- `dart-baseline`: previous library timer behavior; UI/write optimizations still apply, so this isolates KDF cost rather than recreating every old behavior.
- `all`: build all three sequentially **in one job with the same debug signer**, verify each APK and assert equal signing certificates. This enables non-destructive upgrades between comparison variants on a suitable test installation.

Each build uses `--profile --target-platform android-arm64`, enables optional timing and retains default 600,000 iterations for new PINs. Expected artifact names:

- `calculator-messenger-profile-arm64-preview-native`
- `calculator-messenger-profile-arm64-preview-all` (three implementation subdirectories)

Connected equivalents use `connected` in the artifact name. Each implementation directory contains `app-profile.apk`, its `.sha256` and inspection metadata. Diagnostics: `calculator-messenger-profile-build-logs-RUN_ID`. These are expected names, not proof artifacts exist.

Do not replace the existing installed preview if certificates differ. Do not uninstall/clear data. Use its original signer or an owner-approved fresh test Android device/profile. Separate workflow runs can have different ephemeral debug keys; `all` ensures only that the three outputs within that job share a signer. Secure storage/PIN state still must be tested through same-signature app upgrades and real process restarts. Preserve both the package identity and installed data.

Measure repeated cold/warm unlocks on the **same phone**, compare profile against profile (not debug JIT against profile AOT), use the same PIN/work factor/state, and record medians/tail latency plus device/API and thermal/load conditions privately. First measure clean success, then a dirty successful reset, wrong PIN, persisted five-attempt backoff/restart, and backgrounding mid-verification. Verify ordinary calculations/key response, Auth/device/PIN navigation and no private first frame. Do not reduce PBKDF2 settings to make graphs look better.

## Validation and limitations

- Flutter analysis: PASS. Full suite: **95 passed, one hosted integration skipped**.
- Python tooling: **37 passed**, including real compilation/execution of the production Java KDF against independent Python PBKDF2 v1 vectors. The vectors cover 600,000 iterations, leading zeros and 12-digit legacy PINs. Flutter verifies the same independent records using the Dart implementation and leaves clean stored records byte-for-byte intact.
- New regressions cover non-numeric failed-attempt accounting, skipped clean writes, fail-closed dirty writes, persisted reset/backoff/restart, duration-only/idempotent reporting, immediate numeric result and responsive keys, cancelled late navigation and screen disposal. Existing background/relock/PIN/setup/account-isolation tests pass.
- New Kotlin bridge independently compiles against cached official Flutter embedding and Android 36 headers using installed Kotlin 2.2.20; the Java provider probe runs on the desktop JDK. This is not full Android Gradle compilation, real Android provider interoperability or Keystore performance evidence.
- Workflow actionlint: PASS. Local ARM64 profile build: **BLOCKED** because official `flutter_embedding_profile` downloads return HTTP 403. No APK/hash/install/performance result is inferred from cached-header compilation.
- No physical Android device is attached. Actual storage, UI/navigation, thermal/battery, native-provider timings and cross-version device upgrades remain **NOT MEASURED/NOT VERIFIED**. The owner-reported successful preview APK remains valid historical evidence; this change's profile APK needs a successful new CI run.

Reproduce isolated desktop checks:

```sh
./scripts/flutterw analyze
./scripts/flutterw test
python3 -m unittest discover -s scripts/tests -p '*_test.py'
python3 scripts/test-pin-kdf.py
# On a normal Dart development machine with dependencies resolved:
dart run tool/pin_kdf_benchmark.dart
```

In the restricted cloud home, the benchmark can run directly with the Dart VM and the checkout's package configuration; no HOME change, analytics bypass or credential/file permission weakening is needed.
