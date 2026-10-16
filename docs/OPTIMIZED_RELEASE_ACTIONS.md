# Optimized signed APKs on GitHub Free (private repository)

This is the manual internal-release path for `mvasagan099/Calculator-chat-apk`,
ref `refs/heads/codex/phase2-apk-verification`. It produces separate owner-signed
ARM64 and ARM32 APKs only after verification. It never publishes to Play/GitHub
Releases, deploys providers, changes installed data, or certifies device/production
readiness. Application E2EE remains disabled; native protocol tests do not enable it.

## Security boundary: read before adding signing secrets

GitHub Free does not provide enforceable branch protection or deployment
environments for private repositories. Required environment reviewers are also
unavailable on this plan. This workflow therefore deliberately has **no
`environment` or `github.ref_protected` dependency**. The separate
`android-signed-development.yml` retains its protected-environment path; debug
and other CI workflows remain unchanged.

**Repository encrypted secrets are available to eligible workflows throughout the
repository, not just this workflow, branch, actor or reviewed SHA. Anyone with
write access who can modify/run a workflow can bypass these gates and exfiltrate
signing material, including through a same-repository PR with a changed workflow.**
The allowlist, acknowledgments, read-only token, checksum and certificate pin are
not protection from malicious writers or a compromised owner account. A writer
can also change the verifier, fingerprint input, dependencies or upload paths.
Encryption at rest and log masking do not prevent malicious workflow code from
reading secrets. Never assume fork-PR secret withholding protects against writers.

Use this path only if the owner trusts every writer, installed app, deploy key
and token with write/workflow access. Prefer owner-only write access, remove
unneeded collaborators/integrations, and enable strong account authentication.
If contributors are untrusted, **do not store the signing key in this repository**:
build reviewed source and sign on an owner-controlled machine, or use a separately
controlled signing repository/service with enforceable approvals. Upgrading branch
protection alone does not scope repository secrets to protected branches.

These limitations are procedural, not a substitute for enforced independent review.
See GitHub's [protected branch availability](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches),
[environment availability](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments),
and [secure use of Actions](https://docs.github.com/en/actions/reference/security/secure-use).

## What the workflow enforces while its reviewed source is intact

- Only `workflow_dispatch`; no push, PR, `pull_request_target`, reusable-workflow or
  workflow-run release trigger. No PR checkout or PR artifact consumption.
- Secret-free authorization runs before any checkout or third-party action.
  Repository name and immutable repository ID must match. The explicit actor
  allowlist is owner login `mvasagan099` **and account ID `188013739`**. The
  triggering actor must match too. Changes to this allowlist need source review;
  it is not configurable by dispatch input or repository variable.
- Re-runs are rejected (`run_attempt` must be 1). GitHub re-runs use the original
  actor's privileges, so failures require a fresh review and manual dispatch.
- Both acknowledgments must be true. `expected_ref` and GitHub's selected source
  ref must both equal `refs/heads/codex/phase2-apk-verification`.
- `expected_sha` must be exactly 40 lowercase hexadecimal characters, equal to
  both the event SHA and workflow SHA. Workflow path/ref must match this repository
  and branch. There is no default SHA, tag, abbreviated SHA or moving-ref checkout.
- Both downstream jobs check out the authorized SHA with persisted credentials
  disabled. Each confirms `git rev-parse HEAD`. Immediately before signing, the
  build job rechecks actor/account, attempt, expected SHA and tracked-file changes.
  These checks cannot detect hostile runtime behavior in already trusted code.
- `GITHUB_TOKEN` has only `contents: read`; all unspecified permissions are none.
  Actions are pinned to full commits. No signing secrets in job/global env, caches,
  outputs, summaries, diagnostic uploads or dispatch inputs.

Security/SQL/Edge/PIN/Signal checks must succeed first. Each ABI job retains JDK 21,
pinned Flutter 3.44.0, SDK/build-tools 36, NDK 28.2.13676358, CMake 3.22.1, locked
dependency resolution, analysis and Flutter/tooling tests before signing. R8,
resource shrinking, icon tree shaking, application dependencies and features remain.

The signing helper receives the four secrets only in its materialization step.
It refuses existing owner files, verifies the keystore certificate with keytool,
restricts generated file permissions, and never generates an application key or
falls back to debug signing. Build tools necessarily can read the generated key and
password file during the build: review Gradle/plugins/dependency scripts as trusted
signing code. Cleanup runs even on build failure, immediately after build and before
inspection/upload. Hard runner termination can prevent cleanup; use ephemeral
GitHub-hosted runners, never a shared persistent/self-hosted runner for this path.

Each APK must pass real apksigner verification, owner certificate matching (debug
certificate rejected), package/API/launch metadata checks, known-private-credential
scan, exact single ABI with Flutter engine/AOT libraries, and strict size
**less than 50,000,000 bytes**. Equality fails. Checksum and inspection reports
accompany only passing APK uploads. Known-format scans are bounded evidence, not
proof that no possible secret exists. Existing verification/size/signing helpers
and Gradle's no-debug-fallback configuration remain functionally unchanged.

## Owner settings (not configured by this patch)

Keep the repository private. In **Settings → Secrets and variables → Actions →
Secrets**, add repository-level encrypted secrets:

| Secret | Value |
| --- | --- |
| `ANDROID_RELEASE_KEYSTORE_B64` | One-line base64 of the existing owner keystore |
| `ANDROID_KEY_ALIAS` | Existing private key alias |
| `ANDROID_STORE_PASSWORD` | Keystore password |
| `ANDROID_KEY_PASSWORD` | Private key password |

Reuse the original signing identity for upgrades. Back up the key/passwords securely
outside Git. Base64 is not encryption: encode privately, paste directly into the
secret editor, delete temporary copies, and never paste keys/passwords into chat,
issues, command arguments, workflow dispatch fields, logs or source. Use interactive
keytool password prompts on a trusted machine to inspect the certificate. No owner
key or secret is generated, fetched or inspected by this patch.

In the **Variables** tab add repository variable `ANDROID_CERT_SHA256`: the public
certificate SHA-256 (64 hex characters, optional colon separators), not an APK hash.
Independently verify it against the trusted original keystore/certificate. It is
an integrity pin in reviewed source, not a secret or a boundary against admins.

Connected public repository inputs:

| Name | Source / content |
| --- | --- |
| `SUPABASE_URL` | Repository variable; HTTPS project origin |
| `SUPABASE_ANON_KEY` | Repository variable; public publishable/legacy anon key |
| `FIREBASE_ANDROID_CONFIG` | Existing repository secret or variable; complete raw Android console `google-services.json` |

Existing same-named Supabase secret fallbacks remain supported; Firebase prefers
its existing secret over the variable. The validator requires matching Firebase
package `app.calculatorspace.calculator_messenger` and derives public Dart Firebase
identifiers. Firebase is mandatory here. These values become public APK content.
Never supply Supabase service-role/secret keys, Firebase service-account/private-key
JSON, LiveKit secrets or test-account passwords. Backend credentials stay backend
only. Public config validation does not prove deployed services/RLS/provider behavior.
See [Supabase key guidance](https://supabase.com/docs/guides/api/api-keys).

In **Settings → Actions → General**, allow only trusted actions as appropriate,
select read-only default workflow permissions, leave PR creation/approval disabled,
and confirm Actions/private-runner minute and storage allowance. Do not enable
write tokens or secrets for untrusted/fork PRs. Review all workflows and access
before storing repository secrets; the unchanged debug workflow still runs on PRs
but does not reference the four signing secrets. Existing environment-scoped
secrets do not automatically become repository secrets. Keep the protected
signed-development path gated; do not weaken it to make it run on this plan.

## Owner procedure after separately approved publication

1. Review the **final committed SHA containing this patch**, not the pre-patch base
   SHA or a PR merge preview. From an independent trusted checkout fetch the branch,
   inspect the full 40-character SHA, its complete diff/history and exact files at
   that SHA: all workflows, signing/verifier scripts, Gradle, dependency lockfiles,
   build hooks and public config. Independently compare the SHA with GitHub. A SHA
   copied blindly from the dispatch page is not a code review. These inputs record
   the owner's assertion; the workflow cannot prove independent review occurred.
2. Sign in as `mvasagan099`. Open Actions → **Optimized signed Android release APKs**
   → Run workflow. Select branch `codex/phase2-apk-verification`, enter full
   `expected_ref` as above and the independently reviewed `expected_sha`, then
   explicitly accept both acknowledgments. The workflow must exist on the default
   branch; metadata on 2026-10-16 confirms this branch already is the default.
3. If branch movement occurs before dispatch resolves its SHA, the mismatch fails
   closed. Review the new commit and dispatch again. Movement after dispatch cannot
   change the pinned checkout. Do not re-run jobs; make a fresh dispatch after review.
4. Inspect all jobs for the exact reviewed SHA, both ABI jobs and all verification
   gates. Do not call a release complete if only one ABI succeeded. A passing ABI
   may upload independently while its peer fails. No combined release is published.
5. Download `calculator-messenger-release-arm64-v8a-RUN_ID` and
   `calculator-messenger-release-armeabi-v7a-RUN_ID`. Recompute SHA-256 against the
   included `.apk.sha256`, check the signing certificate independently and preserve
   evidence. Both APKs must remain below the byte limit. Follow
   [DEVICE_ACCEPTANCE.md](DEVICE_ACCEPTANCE.md); never uninstall/clear existing data
   to bypass a signature mismatch. Installation/provider/privacy checks are separate.

Artifacts retain the existing build-directory hierarchy and seven-day retention.
Diagnostics retain `calculator-messenger-release-diagnostics-ABI-RUN_ID` and
`calculator-messenger-release-security-RUN_ID`; exact byte contributors and size
reports survive oversized failures. Private artifacts/logs/mapping files are readable
to repository users with appropriate access; distribute only to intended testers.
No private signing file or whole-workspace upload is configured. Masking is only a
backstop; do not add verbose secret/environment dumps or shell tracing.

## Patch baseline and validation boundary

Prepared against branch head `69a6f4214cad480347e635627b8683d05ca88468` on
2026-10-16. Live metadata reports a private repository and `protected: false`.
GitHub Free is the owner's stated plan; billing, secret presence, Actions policies,
environment settings and provider connectivity were not inspected. No settings
change, commit, push, merge, dispatch or APK build is authorized by preparing this
patch. Local gate tests execute the real pre-checkout shell, including negative
actor/ref/SHA/event/re-run/acknowledgment cases; tooling fixtures test signing and
APK/size validation. They do not establish actual APK signatures, ABI sizes,
installation, provider connectivity or production readiness. CI must supply that
build evidence after explicit owner approval and a separate manual dispatch.
