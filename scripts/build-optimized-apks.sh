#!/usr/bin/env bash
# Connected, owner-signed release only. Never substitutes preview/debug signing.
set -euo pipefail
cd "$(dirname "$0")/.."
config_input="${1:-config/local.json}"
: "${ANDROID_HOME:?Set ANDROID_HOME to the Android SDK}"
: "${ANDROID_CERT_SHA256:?Set the public owner signing certificate SHA-256}"
test -f android/key.properties || { echo 'Missing owner android/key.properties' >&2; exit 2; }
test -f android/app/google-services.json || { echo 'Missing Firebase Android console configuration' >&2; exit 2; }
python3 scripts/prepare-client-config.py --mode connected --input "$config_input" \
  --output config/optimized-public.json --firebase-android android/app/google-services.json
./scripts/flutterw doctor -v
./scripts/flutterw pub get --enforce-lockfile
./scripts/flutterw analyze --no-pub
./scripts/flutterw test --no-pub
python3 -m unittest discover -s scripts/tests -p '*_test.py'
# Flutter release defaults retain icon tree shaking; Gradle enables R8/resources.
./scripts/flutterw build apk --release --no-pub --split-per-abi \
  --target-platform android-arm64,android-arm \
  --dart-define-from-file=config/optimized-public.json
for abi in arm64-v8a armeabi-v7a; do
  apk="build/app/outputs/flutter-apk/app-$abi-release.apk"
  evidence="build/apk-evidence/$abi"
  python3 scripts/verify-apk.py "$apk" --android-sdk "$ANDROID_HOME" --variant release \
    --expected-cert-sha256 "$ANDROID_CERT_SHA256" --output-dir "$evidence"
  python3 scripts/apk-size-report.py "$apk" --abi "$abi" --output "$evidence/size.json"
done
