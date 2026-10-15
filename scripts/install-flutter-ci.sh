#!/usr/bin/env bash
set -euo pipefail
# Official Flutter repository, exact version already used by this project.
# The tag was checked against this commit via the official Git HTTPS endpoint.
flutter_commit=559ffa3f75e7402d65a8def9c28389a9b2e6fe42
flutter_path="${RUNNER_TEMP:?GitHub runner required}/calculator-flutter"
git clone --depth 1 --branch 3.44.0 https://github.com/flutter/flutter.git "$flutter_path"
test "$(git -C "$flutter_path" rev-parse HEAD)" = "$flutter_commit"
echo "$flutter_path/bin" >> "${GITHUB_PATH:?}"
"$flutter_path/bin/flutter" --version
"$flutter_path/bin/flutter" config --no-analytics
"$flutter_path/bin/flutter" precache --android
