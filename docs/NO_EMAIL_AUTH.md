# User ID accounts — implementation prepared for review

No hosted Auth settings, database, Edge deployment, secrets, signing identity or
app data were changed. This patch is prepared on the local source corresponding
to remote `e4881e6dff3e5c2b684f13129a05fc5da9f4c20c`. The previously published
11-line release registrant fix and the earlier untracked `supabase/setup-all.sql`
are preserved and excluded from the account patch.

## User experience

Registration asks for User ID (`[a-z0-9_]{3,30}`), Username (display name, trimmed,
1–80 Unicode characters), Password (12–256 characters), and Retype password.
There are no email fields, verification screens or email reset requests. Login
uses User ID/password; legacy accounts use their existing profile handle and
password. Existing UUIDs, display names, profile/public IDs and conversations stay
unchanged. User IDs become immutable; display names and About remain editable.
The public `profiles.username` column holds the login ID; `display_name` holds
the displayed Username. Neither is the internal `auth.users.id` UUID.

Successful signup immediately issues a genuine Supabase session. The client
installs it using `auth.setSession(refresh_token)` and verifies the returned UUID.
It then checks device authorization, displays recovery codes for the owner to
save, and requires device PIN setup. Successful PIN verification opens Chats.
Later logins preserve the local owner-bound PIN and still require calculator
unlock; password login never silently bypasses an existing PIN. Background relock,
biometrics and existing device approval remain intact. PIN replacement on an
approved session still requires isolated server-side password reauthentication.

## Hidden biometric requirement

The calculator has no fingerprint icon or biometric authentication button. Its
keypad, arithmetic engine and immediate arithmetic results are unchanged. With
biometrics enabled in private Settings, entering the correct secret PIN and `=`
starts Android's biometric-only system prompt. Incorrect PINs never start it.
`LockController.unlock` publishes `unlocked=true` only after both proofs succeed;
there is no independent biometric-only unlock method or PIN-only intermediate
unlock. PIN setup's automatic entry uses this same controller gate.

Cancellation, rejection, unavailable enrollment/hardware and plugin errors leave
the messenger locked. Android device-credential fallback and persistence across
backgrounding are disabled. The system prompt's transient inactive transition is
tolerated, but actual backgrounding invalidates the attempt and requests platform
cancellation. Manual relock, session/device revocation, calculator disposal,
continuing a calculation and policy changes also invalidate late results. Pending
attempts cannot run simultaneous PIN verification or biometric prompts. Existing
independent session/device routing and privacy gates remain required after unlock.
Disabling biometrics in private Settings restores PIN-only entry on later attempts.

The production adapter owns one `LocalAuthentication` instance for both prompting
and cancellation. Tests inject a controlled adapter; production always defaults
to the system implementation. The existing PIN verifier, KDF, attempt accounting
and arithmetic path are unchanged. Human time in the biometric prompt is included
in end-to-end profiling time; it is not PIN derivation latency.

Added controller/widget tests cover success, wrong PIN, failure/cancellation,
platform errors, backgrounding with either relock policy, system-prompt inactivity,
repeated attempts, policy changes, relock, disposal, hidden calculator controls and
navigation only after both proofs. These Flutter tests still require execution
with Flutter 3.44.0 and real Android biometric acceptance before release.

The subsequently requested scoped media-picker fix and its separate Android
acceptance boundary are documented in [MEDIA_PICKER_HANDOFF.md](MEDIA_PICKER_HANDOFF.md).

## Auth adapter and atomic identity creation

Supabase password Auth uses an email/phone identifier. The `account-auth` Edge
adapter resolves User IDs server-side and never asks for a real address. For NEW
accounts it generates a random UUID mailbox under **an explicitly owner-controlled
subdomain** configured as `ACCOUNT_ALIAS_DOMAIN`. There is no default domain.
Do not configure another organization's domain, a borrowed address or a real
user mailbox. The operator must own the domain and route it to a non-delivering
mail sink/null-MX configuration; it is not an account-recovery channel. Provider
Auth can expose the alias to its own signed-in user: it is not a secret, an
authorization token or a rate-limit boundary.

Only Admin `createUser` receives that random alias and `email_confirm: true`.
This confirms a server-created synthetic identifier for this account only;
global confirmation settings are not disabled. No confirmation email is sent by
this API. The service role remains solely in the Edge runtime. Passwords are
transient request values passed to Supabase Auth; neither passwords nor their
confirmation enter profile/RPC tables, local secure storage, logs or metadata.

A short-lived, service-only signup intent holds the selected names and HMAC
recovery digests. Admin-created `raw_app_meta_data` references its nonce. The Auth
insert trigger consumes it and inserts the profile/settings/recovery rows inside
the **same database transaction as Auth user creation**. The unique profile handle
constraint arbitrates simultaneous registrations; the losing transaction leaves
no Auth user, profile or recovery row. User-editable `user_metadata` cannot select
login identities or recovery digests. Expired/unconsumed intents are cleaned on
auth traffic; no intent contains a password. Admin response ambiguity does not
cause deletion of a potentially valid account. If creation succeeds but issuing
the session fails, the UI instructs login with the chosen ID/password and code
generation in Settings. No existing user is deleted as compensation.

The service-only alias resolver also supports existing accounts without changing
their Auth identifier. Unconfirmed legacy email accounts stay unconfirmed; this
patch does not silently verify them or transfer ownership. A separately reviewed
owner procedure is required if any such accounts need conversion. Existing users
with a working password can enroll recovery codes in Settings on an approved
device; no recovery credentials are invented for legacy accounts.

## Recovery and sessions

Signup returns eight random 256-bit hex codes once. Only domain-separated
HMAC-SHA256 digests are retained, under `ACCOUNT_RECOVERY_PEPPER`; keep that server
secret stable and backed up. The app displays codes in memory only, requires an
acknowledgment and clears them on sign-out/disposal. It does not save them to disk
or copy them to the clipboard automatically. Losing both the password and all
codes has no email/support bypass. Codes are equivalent to account ownership;
store them offline separately from the phone.

Recovery requires User ID, one unused code, a matching new password, and a fresh
device UUID. A service-only, serialized database claim consumes that code before
any external password reset. It immediately sets a session cutoff checked by
existing RLS/RPC device gates, blocking old sessions even while their JWTs have
not expired. A fresh Auth password session is obtained, other Auth refresh
sessions are revoked, and the database verifies its actual `auth.sessions`
owner/creation time. Completion approves **only that recovery-proven session and
device**, revokes old device records and push tokens, and records a recovery event.
Device approval enforcement is never disabled. The app still requires an existing
PIN or password-proven PIN setup/replacement. Recovery does not claim to terminate
already-connected LiveKit rooms; existing call teardown/provider behavior needs
separate device testing.

Other unused codes stay valid after recovery, so losing the network response
after commit cannot destroy the owner's remaining recovery path. Recovery issues
eight additional codes. Explicit Settings → Generate new recovery codes requires
the account password and an approved session; this operation replaces **all** old
codes. After suspected compromise, complete that rotation and save the new set.
Repeated failed delivery of an explicit rotation can be retried with the password
and approved device. Codes are never returned by a lookup endpoint.

External Auth updates and the application transaction cannot form one distributed
transaction. If recovery fails, the attempted code stays consumed, and old
sessions stay blocked; use another unused code. The Edge handler releases only
its own claim. A hard-crashed worker's claim can be replaced with another UNUSED
code after 15 minutes; recovery completion requires the exact current claim nonce.
Outbound adapter Auth/admin calls have 15-second request timeouts. Verify hosted
worker/provider timeouts remain below the recovery-claim interval before rollout.
Do not automatically clear recovery state or restore old-session access.

## Abuse controls and deployment prerequisites

`account-auth` uses durable, atomic, service-only PostgreSQL hourly counters:
100 requests per action globally, 5 signup/30 other requests per trusted client
address, and 5 signup/15 other attempts per User ID. Approved code rotation is
keyed to the authenticated UUID rather than a client-supplied identity. Failures
count; limits fail closed. Address/identity limiter keys are HMAC digests and
expire after two hours. These intentionally conservative rollout quotas can cause
shared-IP denial of service or targeted ID throttling; tune only after load/abuse
review. User ID unavailability is intentionally disclosed during signup because
handles are publicly discoverable. Login/recovery errors never disclose aliases
or raw provider errors. Unknown-ID login also performs a provider password check;
this is not a claim of cryptographically identical timing.

The operator must supply a **trusted ingress IP header** via
`ACCOUNT_AUTH_IP_HEADER`. The ingress must strip client values and overwrite the
header with one canonical client address. A caller-supplied forwarded chain is not
trusted; comma-separated values fail closed. Verify this with spoofed requests on
staging before enabling registration. If the Supabase gateway cannot guarantee
such a header, deploy an owner-controlled ingress that can, rather than trusting
arbitrary `X-Forwarded-For`. Coarse global/ID quotas still apply independently.
Supabase Auth's own limits remain necessary because its direct token APIs exist.

**Pending owner-approved deployment**, in order:

1. Review the linked staging project's schema/history/backups and migration 012.
   Apply existing migrations through 011 if absent; apply only 012 on an existing
   compatible deployment. Do not reset an existing database or replay the older
   11-migration `setup-all.sql` as an upgrade. CLI generation/deployment was not
   available in this local session; the new migration follows the repository's
   versioned naming convention. No migration history was repaired or fabricated.
2. Securely configure Edge-only `ACCOUNT_ALIAS_DOMAIN`,
   `ACCOUNT_RECOVERY_PEPPER` (at least 32 random characters),
   `ACCOUNT_AUTH_IP_HEADER`, and initially leave `ACCOUNT_AUTH_ENABLED` unset/false.
   Keep built-in service-role/anon/project runtime inputs server-side. These new
   values must NOT be Flutter defines or release workflow secrets.
3. After approval, deploy `account-auth` and run staging tests. Existing
   device-security/delete-account password proofs remain compatible: they resolve
   the current verified Auth user's internal identifier server-side.
4. After approval, disable direct PUBLIC self-signup in Supabase Auth while keeping
   the email/password provider enabled for Admin-created alias accounts. Do not
   globally disable password Auth or silently disable email confirmation for old
   flows. Verify Admin createUser still works with the approved settings. Audit
   existing hooks/SMTP: no email recovery should be delivered for the alias domain.
   These account-specific changes have not been applied by this patch.
5. Verify global/native Auth limits, ingress spoof resistance, legacy account
   compatibility, concurrent signup, one-time recovery, stale claims, interrupted
   responses and immediate old-session RLS denial. Set `ACCOUNT_AUTH_ENABLED=true`
   only after those checks and owner approval. Release the matching Flutter build
   with all existing certificate/size gates, then run two-phone acceptance.

## Tests and verification boundary

- 46 existing Python tooling tests passed locally.
- All 19 Edge tests passed using a cached Deno 2.9.6 runtime, including twelve new
  account handler/helper cases with fake provider/DB ports. This exercises the
  actual handler, including concurrency/error paths; it is not live Auth or SQL
  execution. The earlier twelve-case Node harness also passed.
- Deno typechecking passed for all Edge entry points and hosted test sources with
  the project's pinned dependency configuration and cached dependencies. Existing
  CI discovers the new tests without modifying any signing/size workflow.
- Flutter service/widget/input tests cover duplicate IDs, confirmation/strength,
  immediate sessions, PIN/device gates, relogin, safe errors and no email fields.
  They are added but **not run**: Flutter SDK is unavailable here.
- Disposable PostgreSQL tests cover pre-migration accounts, atomic trigger rollback,
  untrusted metadata, permissions, rate counters, recovery replay/session ownership,
  old-session denial and lost-response fallback. A real concurrent signup test is
  included. They are added but **not run**: local Docker socket access is denied.
- Flutter/provider/device verification remains pending. No APK was built;
  no new hosted signup/login/recovery, schema deployment or Auth settings success
  is claimed. All production services and installed data remain untouched.

Official API references used: [Admin createUser](https://supabase.com/docs/reference/javascript/auth-admin-createuser),
[Admin updateUserById](https://supabase.com/docs/reference/javascript/auth-admin-updateuserbyid),
[signOut scopes](https://supabase.com/docs/reference/javascript/auth-signout),
[Flutter setSession](https://supabase.com/docs/reference/dart/auth-setsession).
