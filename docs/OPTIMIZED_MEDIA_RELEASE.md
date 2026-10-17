# Optimized media-fix release (internal only)

This branch keeps the latest online-only recovery fix for image, camera and
video messages and adjusts the owner's manually gated optimized release
workflow to build the exact SHA of `codex/optimized-media-release`.

**Important: the release APK is signed with the owner RELEASE key.** Android
will NOT update an existing debug APK whose certificate differs. Because the
user's older debug installation reported an unreadable encrypted local cache
and preserved unsent files, do NOT uninstall it, clear data or try a signature
mismatch workaround. Install the optimized release first on a separate
disposable Android device or isolated work profile, or perform a reviewed
backup/migration plan before changing an affected installation.

The workflow still requires BOTH manual acknowledgments; owner login +
immutable actor-ID checks; exact branch matching; a 40-character reviewed
source SHA; identical actual source/workflow SHA; security tests; existing
keystore and certificate fingerprint secrets; and signature and size
verification. No signing keys are generated, committed or read from
the user's device.

Run manually from GitHub Actions → Optimized signed Android release APKs →
Run workflow, choose `codex/optimized-media-release`, check both explicit
acknowledgments after reviewing the exact SHA, set:

- expected_ref: `refs/heads/codex/optimized-media-release`
- expected_sha: SHA of the head commit of this branch (full 40 hex chars).

The expected SHA must be copied after this documentation/workflow commit; do
not paste an earlier commit. Successful artifacts are two ABI-specific signed
release APKs, arm64-v8a and armeabi-v7a, with checksums and inspection.
GitHub must already have the five owner signing inputs and public connected
Supabase/Firebase configuration. A prior release workflow was successful
at an older commit and does not verify that inputs remain configured now.

Do not distribute publicly until online media delivery is tested on real
devices and the encrypted-cache recovery is resolved. The change does not
touch Supabase data, worker schedules, secrets or the current APK.
