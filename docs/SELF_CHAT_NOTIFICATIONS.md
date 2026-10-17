# Self-chat and Calculator notifications — prepared for review

No code was committed/pushed, migration applied, Edge Function deployed, release
record published or APK built. Signing credentials and production Auth settings
were not accessed or changed. The existing account, hidden biometric and media
picker work remains in the combined patch.

## Message Yourself

Chat list and New Chat each expose **Message Yourself**. Contact-selection mode
does not show it, and normal profile search still excludes the current account.
The shared tile captures the account UUID, session UUID and unlock epoch, prevents
duplicate taps, invokes `create_direct(peer: auth.uid())`, then rechecks the same
approved/private session before navigation. No self-contact row is inserted.

Migration 013 extends only the authenticated public `create_direct` entry point.
After `private.require_session()`, an ordinary peer delegates to the original
`private.device_guarded_create_direct` implementation, retaining its blocks,
profile validation, two members and rate limit. The self branch uses the existing
unique `conversations.direct_key` in a separate `self:<internal Auth UUID>` key
namespace. Atomic UPSERT and one membership row make retries/concurrent creation
idempotent. The manually chosen login User ID is not used as an Auth UUID.

A membership trigger rejects other accounts in that self-key namespace. No client
gets new table write permissions, no normal RLS policy is broadened, and no old
conversations/messages are changed. `conversation_list` retains its guarded query,
ordering, previews, expiration and preferences, then adds `is_self` metadata and
the title **Message Yourself**, with no peer ID and unread=0 for self-chat.

Self-chat reuses `send_message`, attachment upload/server validation, UUID retry
identity, replies/edit/delete, encrypted SQLite cache, outbox and synchronization.
Ordinary text, photo, video, audio/voice, documents, contact cards and locations use
the same APIs. First creation needs the server; existing cached conversations and
messages retain their normal offline behavior. View-once and member-mention
actions are hidden for self-chat because they require a peer. Self call controls
are hidden; both existing server call entry points still reject fewer than two
members. Details already prevent self-contact/block actions. Sender exclusion
already prevents notification jobs, receipts and unread counts for own messages;
the new worker relevance function also rejects a recipient who is the sender.

## Generic notifications and secure routing

Incoming **message** notifications, including group messages, have only:

- Title: **Calculator**
- Body: **New update arrived**
- Existing Calculator small icon: `ic_notification`

Provider payloads contain only opaque resource/recipient UUIDs and the activity
kind; no sender/chat name, message, filename, picture or route. Message data cannot
change the display text into a version warning. Existing incoming/missed-call
wording, dedicated call channel, short invitation TTL and answer/reject behavior
are preserved. Calls also receive recipient binding on new payloads.

`private.message_notification_target` centralizes current message/member/settings
eligibility: the message exists, is not deleted/expired/hidden, the recipient is a
member with notifications enabled and conversation unmuted, neither user blocks
the other, and the recipient is not the sender. The service-only
`message_push_target` exposes this to the dispatcher. The client-only
`notification_message_target` first checks the approved session and always uses
`auth.uid()`, never a caller-selected recipient. Neither returns preview content.

The dispatcher rechecks this eligibility at send time, then uses the unchanged
approved-session `notification_tokens` filter. Message FCM TTL is capped by any
message expiry. Foreground local display rechecks the guarded target, keeps
bounded/in-flight deduplication, and uses the same `message:<UUID>` Android tag and
notification ID 0 as the OS FCM display path. Retries replace the existing tray
entry. Notification-open callbacks route only; they never display it again.

For background/terminated apps, Android/FCM renders the one generic notification
payload. The background Dart handler still creates local notifications only for
data-only call invitations, preventing a second local message display. Android
permission/channel settings, Doze, offline delivery and force-stop restrictions
still apply. No delivery success on an actual phone is claimed here.

A notification tap only records an allowlisted activity with opaque IDs. It never
sets `unlocked`, creates a session or grants device approval. Routing waits for PIN
and any enabled biometric gate, owner/session/device authorization and the media
handoff privacy gate. It allows Calculator/PIN's ordinary post-unlock navigation
to finish before resolving the notification, so a fast result is not overwritten
by `/chats`. It then rechecks the message via the guarded RPC; call-history and
version targets also require an authorized lookup. The original owner, session
UUID and unlock epoch must still match after all asynchronous work. A different
recipient, deleted/expired/muted/blocked target, device revocation, logout or a
stale callback cannot navigate a newer session. Logout clears pending/tray state.

Dispatch checks and FCM enqueue are not one distributed transaction. Settings or
message deletion after an already accepted provider send cannot recall that send;
generic text may remain in the Android tray. TTL limits delayed delivery, while
tap-time checks prevent opening stale/unauthorized messages. These boundaries must
be included in Android/staging acceptance, rather than claiming instant recall.

## Real application-version notices

There is no invented update warning attached to a chat message. A separate local
notice uses **Update to the latest version** only after checking a trusted release
feed against the installed Android package. Migration 013 adds the private,
RLS-enabled, client-inaccessible `private.android_releases` table, initially empty.
`latest_android_release(target_abi)` is a session-guarded read of published,
non-future release metadata. There is no client publishing API.

The native read-only `appIdentity` method supplies the installed build number,
package ID, running ABI and current certificate SHA-256. It does not generate,
replace or read a private signing key. Client validation requires a strictly
higher integer Android build, matching package/ABI/certificate, a SHA-256 APK
checksum, past publication time and an HTTPS APK link strictly inside this
repository's GitHub Releases download path. A wrong ABI, different signer,
unpublished/same/older build, malformed URL or absent feed produces no notice.

After private session startup, version checking runs without blocking messaging
startup and respects the user's notification setting. The version notice opens
private Settings only after all unlock/ownership checks and a fresh version
lookup. The Settings download action revalidates that same release and private
session, then opens the trusted link in the external browser. It never downloads,
executes or installs an APK automatically. No new permission/package is added.

**Future publication is a separate owner operation.** Before marking any record
published, the owner must verify a real available APK, exact native build/ABI,
package, existing signing certificate, strict size gates and actual SHA-256, then
approve its release/download URL. The feed trusts that server publication; it
does not independently download/verify the binary merely to display a notice.
Certificate fields use uppercase SHA-256 without colons; APK hashes use lowercase.
No row or placeholder version has been published by this work. Do not seed a
fake production release just to exercise the notice.

## Verification and rollout boundary

Available checks passed locally:

- 46 existing Python tooling cases.
- 22 Deno Edge cases, including generic message privacy, recipient binding,
  stable tags/icon, expiry TTL and background/terminated payload structure.
- Type checking of all Edge entry points/hosted test sources with project-pinned
  cached dependencies.
- 14 native picker cases with Android/channel doubles, preserving earlier work.
- `InstalledAppIdentity` compilation against Android SDK 36. This does not replace
  full Flutter/Gradle APK compilation or prove device runtime behavior.

Added but pending execution:

- Flutter tests for self entry points and no contact insertion, stale self
  navigation, generic/deduplicated foreground display, eligibility rejection,
  recipient binding, guarded notification routing and real-version validation.
  Flutter analysis/tests cannot run here because the SDK is unavailable.
- Disposable SQL tests for idempotent/single-member self-chat, replies/edit/delete,
  every normal media category, no self jobs/unread, cross-account RLS/storage
  isolation, service-only RPC permissions, muted/blocked/hidden/deleted/expired
  targets, device revocation, and unpublished/future/ABI release filtering.
  A true concurrent `create_direct` race test is wired into `test-database.sh`.
  The database test attempt was blocked by Docker socket permission denial.
- Actual FCM foreground/background/terminated delivery, Android notification tags,
  permissions, cold-start PIN + biometric routing, real media persistence, offline
  sync and two-account device revocation require staging and authorized phones.
  Existing media-picker Home/Recents/OEM signal acceptance remains pending too.

The Supabase CLI is unavailable locally; migration 013 follows the existing ordered
filename convention and is prepared for review, not recorded/applied as hosted
history. After separate deployment approval: verify current schema/history and
backups, validate migrations 012/013 on staging, run SQL/Flutter/security tests,
apply 013, then deploy the matching push dispatcher and client. Do not deploy the
new dispatcher against a schema lacking `message_push_target`: it fails closed
and leaves leased jobs for retry. Review advisors and migration history with a
working CLI before any hosted rollout. Old ordinary direct chats remain intact.

The no-email adapter still has its separately documented domain/ingress/recovery
configuration gate. This patch does not enable it, change Auth settings, alter
Supabase/Firebase/LiveKit production data, publish an APK or touch release signing.

References: [Supabase database functions](https://supabase.com/docs/guides/database/functions),
[RLS](https://supabase.com/docs/guides/database/postgres/row-level-security),
[FCM Android message options](https://firebase.google.com/docs/reference/fcm/rest/v1/projects.messages#androidnotification).
