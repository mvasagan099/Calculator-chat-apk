# Calculator Messenger

A Flutter Android app that opens as a functional calculator and unlocks a private messaging UI after the owner enters their configured PIN and presses `=`.

**Phase 1 runs locally without service credentials.** Its messenger screens contain clearly labelled, read-only development fixtures. They never impersonate Supabase messages or send messages/calls. Existing connected-mode source and backend files are preserved for Phase 2 deployment and testing.

Android 10/API 29 and above. Flutter 3.44.0, Dart 3.12.0, Riverpod, GoRouter and Supabase Flutter. Light/dark themes and responsive portrait/landscape layouts are included.

## Phase 4 status

**Application E2EE remains disabled.** The isolated official Signal Java/JNI prototype passes 17 genuine protocol/integrity checks; no Flutter crypto bridge, encrypted message transport or cryptographic multi-device identity is being represented as complete. Existing direct/group messages and media remain server-readable. See the [encryption assessment and design](docs/ENCRYPTION_DESIGN.md).

Connected-mode source now includes disappearing messages, view-once photos/videos, opt-in device/session approval and revocation, separate online/photo/invitation privacy, and stronger cache/media cleanup. **66 Flutter tests, seven PostgreSQL suites, five Edge tests and the native probe pass locally.** Hosted/new provider flows and Android behavior remain blocked. The [Phase 4 feature-status report](docs/PHASE4_SECURITY.md) separates implementation from verified scope and gives the coordinated rollout steps.

## Phase 3 status (historical)

Connected-mode improvements include encrypted local chat wallpapers, stable message ordering, paginated-history refresh, safer offline retries/read acknowledgments, presence privacy and lifecycle cleanup, bounded attachment forwarding/downloads, audio/recorder cleanup and call-end retry. **53 Flutter tests, five Edge tests, four PostgreSQL suites and 11 public-config tests pass.** One hosted Flutter test is skipped; the hosted runner reports 16 BLOCKED scenarios.

The Android debug build still fails on the official Flutter Maven host's proxy CONNECT 403. No APK/checksum or hosted Supabase/LiveKit/FCM success is verified. No physical devices or release keystore are available. See the [Phase 3 report and acceptance matrix](docs/PHASE3_BETA_READINESS.md) for changes, evidence and precise owner steps. This is not a beta-ready release.

## Run Phase 1

Install Flutter, a full JDK 21 and Android SDK 36. This cloud checkout has the tools under `/workspace/toolchains`; `scripts/flutterw` selects them. On other machines it uses Flutter from PATH.

```sh
./scripts/flutterw pub get --enforce-lockfile
./scripts/flutterw analyze
./scripts/flutterw test
./scripts/flutterw run
```

1. On a fresh installation, create and confirm a **4–8 digit PIN**.
2. Setup returns to the calculator without unlocking the messenger.
3. Enter your PIN and press `=` to open the local preview.
4. Use Chats, Updates, Calls, Groups, Settings, profile and conversation screens. Search and navigation work; sample message composition and calling are explicitly disabled.
5. Return to Calculator, background the app or let the idle timeout expire to relock. Every cold launch starts at the calculator after setup.

The PIN is never hardcoded or stored as plaintext. A salted PBKDF2-HMAC-SHA256 verifier (600,000 iterations) and persistent exponential attempt backoff live in Android Keystore-backed secure storage. Optional biometric unlock is enabled from Settings after PIN confirmation and requires an enrolled device biometric. FLAG_SECURE protects recent-app previews. Actual Keystore, biometric, OEM and screenshot behavior still require device testing.

Local preview PIN/settings use a separate namespace from connected-account PIN/settings. Changing a PIN requires its current value. There is no local recovery bypass; clearing app data resets the development preview. Existing longer PIN verifiers from earlier builds remain accepted, but new PINs use the requested 4–8 digit range.

## Build Android APKs

```sh
./scripts/flutterw build apk --debug
./scripts/flutterw build apk --release
```

Expected paths after a successful build:

- `build/app/outputs/flutter-apk/app-debug.apk`
- `build/app/outputs/flutter-apk/app-release.apk`

**No APK exists in this environment.** The debug command was retried in Phase 4 and remains blocked by proxy HTTP 403 during CONNECT to `storage.googleapis.com/download.flutter.io`. A release was not attempted this phase because signing credentials are absent. Compilation and installation are not verified. See the [latest debug log](docs/phase4-debug-build.txt), [Phase 4 report](docs/PHASE4_SECURITY.md) and [release instructions](docs/RELEASE.md).

Debug signing uses Android's standard development key. A distributable release requires your private signing configuration in ignored `android/key.properties`. Without it, the release configuration is unsigned; no production credentials or debug-signing fallback are invented.

## GitHub Actions build fallback

`.github/workflows/android-debug.yml` installs the exact official Flutter version, runs locked dependency resolution, analysis and tests, builds a signed debug APK and verifies its signature, application ID, minimum API and known secret formats. On success it uploads **calculator-messenger-debug-preview** or **calculator-messenger-debug-connected**, including SHA-256 and metadata. Build logs are uploaded on failure. Workflow lint passed and the source was pushed to [codex/phase2-apk-verification](https://github.com/mvasagan099/Calculator-chat-apk/tree/codex/phase2-apk-verification). GitHub API access is blocked, so no completed workflow artifact is claimed. See [download/run instructions](docs/RELEASE.md).

For connected builds, first prepare public config and Android Firebase resources:

```sh
python3 scripts/prepare-client-config.py --mode connected \
  --input config/local.json --output config/build-public.json \
  --firebase-android android/app/google-services.json
./scripts/flutterw build apk --debug --dart-define-from-file=config/build-public.json
```

Omit `--firebase-android` only when Firebase identifiers are absent; Supabase messaging can be tested before notifications. The validator rejects server credentials/test passwords and checks the console Android package and matching Firebase IDs. Generated resources/config are ignored by Git.

## Phase 2: connect real services

Phase 1 is selected by the `LOCAL_UI_PREVIEW` Dart define, which defaults to `true`. To select the preserved connected implementation, set it to `false` and supply the **public** `SUPABASE_URL` and `SUPABASE_ANON_KEY` values. The template `config/example.json` selects connected mode; replace its example identifiers in an ignored `config/local.json` file before using it.

```sh
./scripts/flutterw run --dart-define-from-file=config/local.json
```

Follow the [Phase 2 handoff](docs/PHASE2.md), [current verification report](docs/PHASE4_SECURITY.md), [hosted-test guide](docs/HOSTED_TESTS.md) and [provider setup guide](docs/DEPLOYMENT.md). Connected mode requires account authentication and a separate account-bound PIN. A local preview PIN never authorizes a Supabase session.

Never put Supabase service-role keys, LiveKit secrets, Firebase service-account JSON, signing passwords or private keystores in Flutter config or Git. Client configuration is compiled into APKs and is public.

## Architecture and verification

`lib/features/calculator` contains arithmetic and calculator UI. `lib/core/security` contains PIN/session protection; `lib/features/preview` contains isolated local fixtures and Phase 1 navigation. Connected features, typed models, repositories and services remain separated under `lib/features`, `lib/models`, `lib/repositories` and `lib/core`.

The retained Supabase migrations/Edge Functions, private Storage policies, authenticated Realtime paths, media, LiveKit and FCM integration code are **not validated hosted services**. No provider projects or physical Android devices were supplied. Optional phone OTP, address-book sync, group calling and E2EE are not implemented. HTTPS/RLS are not E2EE.

See [test evidence](docs/TESTING.md) and [security model](docs/SECURITY.md). The hosted two-account test is explicitly skipped until disposable verified accounts and public configuration are supplied. Backend checks can be reproduced with:

```sh
./scripts/test-database.sh
deno check --config supabase/functions/deno.json supabase/functions/*/index.ts supabase/tests/hosted*.ts
deno test --config supabase/functions/deno.json supabase/functions/_shared/*_test.ts
```

Use the existing checkout in future cloud tasks; no additional worktree is needed. The source and debug workflow were pushed to `codex/phase2-apk-verification`; workflow execution and artifacts must be verified separately.
