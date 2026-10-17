# Messenger appearance and maximum chat visual-media lifetime

Prepared locally. Not deployed, pushed, signed or packaged. Earlier account,
biometric, picker, self-chat and notification patches remain required and intact.

## Appearance

Private Settings → Chat appearance selects light/dark/system independently of
calculator appearance. Messenger style selects Default, Instagram-like or
Telegram-like. DeviceSettings persists stable names under messenger.theme and
messenger.appearance; unknown values default safely. The root applies the
messenger theme only inside the private Navigator content. Public calculator,
registration, recovery, PIN and device-approval routes retain the baseline theme;
PrivacyGate explicitly uses baseline calculator brightness during transitions.
Default keeps the current scheme. Other themes use original Material colors,
subtle static purple/pink gradients, rounded bubbles or compact blue bubbles.
Inherited colors style navigation, chat list, timestamps and composer. No fonts,
images, logos, packages or animations added. Existing wallpapers take precedence.

## Server policy

Forward-only 202610160014_chat_media_deadlines.sql adds a separate attachment
media_expires_at; it does not shorten message/text history. Every validated chat
image/video gets its immutable Storage created_at + 48-hour ceiling, even in
self chats and groups with disappearing messages disabled. Earlier message
expiry and view-once's existing 24-hour policy still win. Audio/documents/text
and status-media's 24-hour policy stay unchanged. Profile avatars are untouched.
New group icons use the reserved /icons/ namespace and cannot be attached to
messages; existing persistent icon references remain exempt. Changing a group
icon cannot promote an ordinary expiring chat attachment into persistence.

validate-media computes SHA-256 from validated bytes. A service-only RPC atomically
serializes fingerprint registration and takes the earliest deadline. Exact-byte
retries, forwards and duplicate uploads cannot refresh it. The app forwards the
exact original bytes without recompression. Minimal private SHA/deadline records
survive deletion to prevent resurrection. These hashes are not exposed to clients.
A newly edited/re-encoded file is different content; this is not perceptual media
recognition. MP4 handler validation prevents video renamed as audio/M4A from escaping the policy. Existing nonempty installations require a trusted bounded hash
backfill before accepting reuploads, because historical hashes do not exist.
This project's inspected chat-media bucket was empty, so no hash backfill was
needed in that snapshot. Do not infer this remains true at deployment time.

A restrictive Storage policy allows visual bytes only through authenticated
object.get_authenticated requests before the deadline; ordinary membership,
blocking and device policies still apply. Visual signing is denied, not delegated
to a client-selected TTL. chat_media_deadline verifies the same approved session
and current message membership. Visual downloads use authenticated Storage;
documents/audio retain their existing short signed URLs. Service-only view-once
claims independently check the upload deadline and the worker rechecks before
returning bytes. Neither transport grants a new public URL.

Old signed URLs issued BEFORE cutover are bearer capabilities and do not
re-evaluate RLS. Before enabling a nonempty deployment, inventory their maximum
TTL and either drain them before the relevant deadlines or perform an approved
server-side object-path cutover that removes the old paths. Never claim an RLS
change revokes an already issued signed token. The inspected bucket had zero
chat objects, hence no such live URLs in that snapshot. Staging must verify the
actual Storage operation identifiers and real signed/authenticated HTTP behavior.

## Cleanup and local behavior

Authenticated maintenance queues at most 500 expired paths per pass, including
unattached uploads, drafts and missing objects with provenance. Existing orphan
GC can remove abandoned bytes earlier. Persistent group icons are excluded.
Storage remove must succeed before complete_media_cleanup removes attachment
rows, validation rows and object provenance and acknowledges durable jobs.
Storage failure retains jobs; acknowledgement failure safely retries removal.
Maintenance reports visualQueued/mediaDeleted and service-only due-job count/oldest-due health. Run at least every minute and
alert on failed invocations, old due jobs and growing backlog. Access denial is
immediate via RLS; physical deletion occurs on the next successful worker pass,
so outage/backlog affects physical deletion latency, not new-read authorization.
No storage.objects rows are directly deleted by the production SQL migration.

The app uses memory images and managed private video files, clears decoders and
bytes on deadline/relock/background, deletes managed files at expiry and at
startup, and strips expired attachment references from encrypted SQLite/cache
and outbox without dropping text history. A missing visual attachment shows
"Media expired". Existing exported/share copies on other devices cannot be
revoked; this policy governs server storage and app-managed copies. OS suspension
can defer local timers; backgrounding immediately destroys active previews and
startup clears owned temporary files before private UI opens.

## Read-only preflight performed 2026-10-16 UTC

Connected account: flutter chat. Project vjjvfshpzihbrdakbzct (chat app).
Application tables exist; storage operation helpers exist.
supabase_migrations.schema_migrations is ABSENT. This indicates missing history,
not an empty application schema. Do not replay setup-all.sql or the base migrations.
Observed attachment rows: 0; chat-media objects: 0; expired chat visual objects: 0.
One status-media object, 464700 bytes, was present and excluded from this policy.
No rows or objects were modified. Schema/history reconciliation remains a gate.

## Deployment plan — separate approval required

1. Run supabase/media_retention_preflight.sql read-only against the confirmed ref.
   Reconcile actual function definitions, RLS and migration history with 001–013;
   repair history only after explicit review. Supabase CLI is absent locally, so
   the forward migration filename follows this repository's sequence manually.
2. In a disposable Supabase environment, apply all pending changes in order;
   run all database/RLS/race tests and Flutter tests, verify both themes and
   real authenticated Storage signing denial. Test retries and worker outages.
3. Re-run impact counts. Report expired object count, bytes, metadata, orphan and
   shared-icon impact. Obtain explicit approval before applying the migration or
   running any cleanup that can remove user media. No deletion is authorized here.
4. For nonempty pre-existing media, complete trusted fingerprint backfill and old
   signed-URL cutover/drain before advertising the 48-hour guarantee. Do not
   launch this policy until those gates pass; no bypass is provided in the app.
5. Deploy the approved forward migration plus validate-media, maintenance and
   view-once workers, then the compatible app. Older clients that request visual
   signed URLs will fail closed and need upgrading. Inspect RLS advisors.
6. Schedule/monitor the existing secret-authenticated maintenance worker. Verify
   expired bytes disappear via Storage API, metadata is gone, text remains, and
   no unauthorized user, revoked device or old URL can fetch expired content.

Release workflow, owner signing identity and strict 50,000,000-byte gates remain
unchanged. No APK size or installability result is claimed by this patch.

## Validation status

Passed locally: 46 Python tooling tests; 31 Deno tests (including five MP4 audio/video classifier tests and four cleanup
ordering/retry/batch tests); cached Deno check of all Edge entrypoints and hosted
test sources; 14 native picker tests with framework doubles; Actionlint with
ShellCheck; bash syntax and whitespace checks.

Added 18 Flutter test cases for both styles/brightnesses, preference restart,
calculator theme isolation, cache/text retention, managed-file deletion, and
late image callbacks after expiry/lock/background. They are UNRUN: flutter and
dart are not installed here. SQL/RLS suites including the new deadline suite
are UNRUN: Docker socket permission denied. Physical Android/FCM/biometric and
actual Supabase Storage HTTP acceptance remain required. No APK was produced.

Remote security advisors were read only: five informational private deny-by-
default RLS tables, 28 existing authenticated SECURITY DEFINER API warnings,
and leaked-password protection disabled. This patch did not change hosted Auth
settings or those APIs. Review intentional RPC exposure against
https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable
and the Auth setting against
https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection
before release. These are baseline observations, not a clean post-migration scan.

References consulted: current Supabase Storage access-control and downloads
documentation. changelog.md could not be retrieved by the browsing tool because
it rejected its Markdown content type; actual Storage operation helpers were
confirmed present with read-only catalog inspection.
