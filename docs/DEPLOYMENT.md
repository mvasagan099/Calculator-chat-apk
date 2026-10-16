# Service deployment

Phase 1 defaults to a local preview without provider initialization. For connected mode set `LOCAL_UI_PREVIEW` to `false` in the public build configuration, as in `config/example.json`. No provider projects were supplied. These steps must be completed in accounts you control. Keep client identifiers and server credentials separate. Neither saving an environment draft nor building source provisions these services.

Phase 5 preserves the original ten migrations and adds migration 011; nine Edge entry points require coordinated deployment. No deployment was performed here. No confirmed remote project, Firebase console configuration, LiveKit credentials or staging accounts are available. Local SQL/Edge tests pass; deployment and actual two-user behavior remain BLOCKED. [Current evidence](PHASE5_CALLS.md).

The ignored `config/local.json` generated for this phase's build is **preview only**. Prepare a separate ignored file with real public identifiers, then validate connected mode before testing providers:

```sh
python3 scripts/prepare-client-config.py --mode connected \
  --input config/connected-public.json --output config/local.json \
  --firebase-android /private/local/path/google-services.json
```

The Firebase input is Android console configuration, never a service account. Omit its option only when intentionally testing without FCM. Server credentials and test passwords are rejected as build input. This command configures a client build; it does not deploy services.

## Phase 6 deployment checkpoint

No provider deployment was performed. The [current release audit](PHASE6_RELEASE.md) confirms no linked project/hosted-test config, Firebase Android file, LiveKit credentials, owner signing or devices. All 11 existing migrations/nine functions are preserved; the client cache fix requires no server migration. Follow the exact staging target/schema/history/backup review below before remote writes. Public config and passing local SQL tests do not establish a deployed/authorized project. Current hosted runners report 16 general and six privacy scenarios BLOCKED.

Prepare connected public config, deploy/verify services, then execute [DEVICE_ACCEPTANCE.md](DEVICE_ACCEPTANCE.md). The ignored local config used here remains preview-only. Release/signing/environment protection steps are in RELEASE.md; no CI workflow publishes to Play or bypasses provider/device gates.

## Supabase

1. Select the owner-authorized existing Supabase staging project; do not create another project when a suitable project already exists. Enable email confirmation, configure SMTP and password strength/rate limits, set a suitable email redirect policy and register `app.calculatorspace.calculator://auth-callback`. Set the site URL to a domain you control for email fallback. Android custom schemes are not domain-verified; for production configure a verified HTTPS Android App Link and update the redirect URI in both manifest and auth calls.
2. Before any migration or function deployment, confirm a dedicated **development/staging** project in the dashboard. Record its exact project ref and HTTPS origin. No target is currently configured in this checkout; do not infer a target from the local `project_id` label in `supabase/config.toml`. Use your own account to authenticate the official CLI and inspect the linked target:

   ```sh
   supabase projects list
   supabase link --project-ref CONFIRMED_STAGING_REF
   supabase migration list --linked
   supabase db push --linked --dry-run
   ```

   Run `supabase/remote_preflight.sql` in that project's SQL editor to inspect tables, RLS/policies, grants, publication and buckets without reading user data. Review the remote migration versions, schema and any naming conflicts against the eleven local migrations. On an existing deployment, back up first and review function/policy replacements and data effects. Do not automatically repair migration history, reset a remote database, drop unknown objects or use `--include-all` to force mismatched history. Fresh migrations assume a compatible/new schema and do not backfill profiles for pre-existing Auth users. Resolve drift explicitly before applying anything. Then, only on the confirmed reviewed target:

   ```sh
   supabase login
   supabase link --project-ref CONFIRMED_STAGING_REF
   supabase db push
   ```

   This applies the eleven versioned migrations; obtain explicit owner confirmation on the reviewed target before running it. They create user-data tables, indexes, constraints, Auth profile trigger, RLS, private Storage buckets, authenticated RPCs, and Realtime publication entries. Review migrations before applying to an existing project. The application uses public profile discovery by username/public ID; email addresses are never in public profiles.
3. In Realtime settings enable private-channel authorization and disable public-channel access. Database changes use the caller's RLS; typing/presence use private `conversation:<uuid>` topics. Message history lives in PostgreSQL.
4. Set server secrets securely using the dashboard or `supabase secrets set --env-file <ignored-file>`. Built-in `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` are supplied by Supabase. Add:

   | Secret | Purpose |
   | --- | --- |
   | `LIVEKIT_URL` | `wss://` LiveKit endpoint |
   | `LIVEKIT_API_KEY` | LiveKit server API identity |
   | `LIVEKIT_API_SECRET` | LiveKit token/webhook signing secret |
   | `FIREBASE_SERVICE_ACCOUNT` | Entire service-account JSON as a secret string |
   | `MAINTENANCE_SECRET` | Random worker authorization string, at least 32 characters |

   These are real server-side values, not proxy-placeholder environment variables and not Flutter defines. Do not paste them into chat or Git. Grant the Firebase account only the permissions required to send FCM messages.
5. Deploy:

   ```sh
   supabase functions deploy livekit-token
   supabase functions deploy validate-media
   supabase functions deploy delete-account
   supabase functions deploy livekit-webhook
   supabase functions deploy maintenance
   supabase functions deploy dispatch-push
   supabase functions deploy view-once
   supabase functions deploy device-security
   supabase functions deploy call-control
   ```

   `verify_jwt=false` is deliberate: user functions verify the supplied bearer using Auth `getUser`, supporting current Supabase signing keys; workers require `x-worker-secret`; the webhook verifies LiveKit's signature and body hash. There is no unauthenticated privileged entry point.
6. In Supabase Vault create `calculator_worker_url` = `https://PROJECT_REF.supabase.co/functions/v1/maintenance`, `calculator_push_url` = the `dispatch-push` URL, and `calculator_worker_secret` = the same worker secret. Enable Cron/pg_cron, pg_net and Vault. Run `supabase/schedule.sql` in the SQL editor. It schedules cleanup each minute and push dispatch every five seconds. Review worker responses in Cron/Edge logs without logging payloads or credentials. Verify a real expired status disappears from the database and Storage, rather than just being hidden on a client.
7. Put the project's HTTPS URL and **public publishable/anon** key in ignored `config/local.json`. No service-role credential goes into the APK.

Buckets reject oversize and unsupported MIME uploads. `validate-media` downloads with the user's token, checks file signatures/UTF-8 and records a server-only validation; message/status/profile writes require that validation. These checks are not malware scanning or full file-format sandboxing. Add a malware-scanning/quarantine pipeline if required for your release and never execute received files. Individual attachments are limited to 25 MB; avatars to 5 MB. Clients do not render HTML attachments.

Workers delete objects through the Storage API, not direct object-table deletes. They clean expired status media, soft-deleted media, old orphan uploads/avatars, stale push tokens, edit history and notification/rate-limit records. Messages without an expiration policy are retained until a permitted deletion/account cleanup; expiring/view-once media also follows the Phase 4 retention jobs; edit-history retention is 30 days and old notification jobs seven days. Account deletion requires password reauthentication, removes owned media, erases authored message bodies, transfers lone-admin groups where possible and deletes the Auth user/profile with cascading user rows.

The default worker processes 50 notifications per batch, leases jobs and retries failed dispatch up to eight times. Monitor exhausted jobs. FCM has at-least-once delivery characteristics; the app uses stable notification tags for calls and the database uses unique recipient/resource jobs. High-volume deployments need worker concurrency/load testing and an operational dead-letter queue.

## Firebase Cloud Messaging

1. Create a Firebase project and Android app with package ID `app.calculatorspace.calculator_messenger`. If you change the package identity, update Android namespace, Kotlin package paths, Firebase registration and any auth app-link configuration together.
2. Enable the Firebase Cloud Messaging HTTP v1 API. Generate or bind a server service account with FCM send permission, then save its JSON as `FIREBASE_SERVICE_ACCOUNT` in Supabase secrets.
3. Download the Android console `google-services.json` to ignored `android/app/google-services.json` (this is public Android client metadata, never a server service-account JSON). Run the preparation command below with your public Supabase config. It verifies the exact Android package and extracts/compares Firebase app/project/sender/API identifiers, writes a separate public build config, and installs the validated console JSON at ignored `android/app/google-services.json`. Google Services Gradle plugin **4.5.0** is declared once in `android/settings.gradle.kts` and applied in the app module when this file exists. The plugin generates native resources for FirebaseInitProvider, including terminated-process startup. The preparer removes only its own legacy `firebase_public.xml` so resources are not duplicated. Provider-free builds remain supported without a console file.

   ```sh
   python3 scripts/prepare-client-config.py --mode connected \
     --input config/local.json --output config/build-public.json \
     --firebase-android android/app/google-services.json
   ./scripts/flutterw build apk --debug --dart-define-from-file=config/build-public.json
   ```

   `FIREBASE_API_KEY`, `FIREBASE_APP_ID`, `FIREBASE_SENDER_ID`, `FIREBASE_PROJECT_ID` may be omitted from local.json when they are derived from the console file. If supplied, they must agree with it. For Supabase-only testing, omit Firebase fields and the console argument. Public configuration and the Android console file must never contain a service-account private key. CI accepts `FIREBASE_ANDROID_CONFIG` as **raw JSON text**, not base64: save the complete console-file contents in the GitHub Actions secret of that name (the existing repository-variable fallback is retained). Both Android workflows validate and materialize the file before Gradle runs. An existing different console file is preserved and causes preparation to fail. Native Android initialization also works from the console file alone; derived Dart identifiers are optional but must match when supplied. No Analytics dependency is added. Firebase automatic registration is disabled in the manifest; the unlocked account explicitly registers after checking permission/preferences.
4. Verify the server FCM service-account `project_id` matches the Android console project, and verify the device has Google Play services. Open Settings → Notifications after signing in/unlocking. Grant Android's notification permission. Tokens are registered for the authenticated account, rotated using Firebase registration events, and removed on logout/disable. Confirm the actual token row exists without copying its value into logs.
5. Send messages/calls between the two test accounts. Verify worker jobs are marked sent, HTTP v1 sends succeed and notification channels are enabled. FCM payloads always say **Calculator / New activity** and contain only routing IDs. Android renders background/terminated notifications; Flutter renders foreground ones. No message content is fetched by the background isolate.

Notification delivery is best effort. Android force-stop prevents delivery until the user launches the app again; OEM battery restrictions can delay it. There is no attempt to bypass those restrictions or silently start microphone/camera capture. An incoming notification tap goes through unlock before the call can be answered. No full-screen incoming-call UI is requested while locked. Active calls request microphone/camera permission before capture, then start an explicit foreground service with a visible generic call notification and an End action. Cancellation invalidates pending connection steps; service cleanup and End actions are tied to a specific connection attempt so stale work cannot stop a newer call. Test foreground-service permission/start restrictions and microphone/camera behavior on each supported Android version.

## LiveKit

Use LiveKit Cloud or a supported self-hosted deployment with HTTPS/WSS, trusted TLS, UDP connectivity and TURN/TLS fallback. Configure LiveKit's advertised public addresses and firewall ports from its current deployment documentation. Supabase does not relay call media.

Save the server API key/secret only in Supabase. Configure the LiveKit webhook URL as `https://PROJECT_REF.supabase.co/functions/v1/livekit-webhook` with events including `room_finished`. Its receiver verifies the signed webhook. The token function calls `authorize_call`, which checks the existing participant, both current conversation memberships, blocks, call state and age, then issues a 90-second room-scoped token (current migration 011/Phase 5 implementation). Apply migration `202610150007_call_authorization.sql` before deploying the updated token function. A callee must accept before obtaining a token. Tokens are not an E2EE implementation and token expiry does not itself terminate an already connected participant.

Use short room empty/departure timeouts and monitor webhooks. The SQL worker marks unanswered ringing calls missed and caps accepted call metadata at two hours and closes ended LiveKit rooms through its server API; the webhook closes metadata when a room finishes. Test timeout, disconnect, cancellation, busy and reconnect paths. Group calling has implemented authorization/UI and local tests; actual group SFU media is not verified. Do not distribute until both physical devices can exchange real audio/video over Wi-Fi, mobile data and a TURN-only restrictive network.

## Cloud network requirements

This instance's network draft adds `storage.googleapis.com`, `maven.google.com`, `dl-ssl.google.com`, and `redirector.gvt1.com`, plus `api.github.com` for workflow status/artifact operations, to the existing package-manager presets. Saving that draft did not apply it: review/save in environment settings and publish through the product. The observed blocker is HTTP 403 on `storage.googleapis.com/download.flutter.io`; there were also transient 503s at Google's Maven repository. Preserve TLS and checksum verification. Retry the APK build after the network change applies.

For runtime testing, also allow your exact Supabase HTTPS/WSS hostname, LiveKit HTTPS/WSS hostname and applicable media/TURN destinations. Supabase workers need Google's `oauth2.googleapis.com` and `fcm.googleapis.com`, plus your LiveKit endpoint. These workers run in Supabase, not inside this Codex machine. No backend credentials currently exist in this environment.

## Current missing configuration

No authorized Supabase link, public URL/key, remote schema/history access, Firebase Android console config, FCM service account, LiveKit endpoint/key/secret, Cron/Vault worker secrets, verified disposable accounts or release keystore is available. No remote migration/function has been deployed. Put server secrets in Supabase, public identifiers in build configuration/GitHub repository variables, and test passwords only in ignored hosted-test configuration. See HOSTED_TESTS.md and PHASE2_VERIFICATION.md for exact blocked results and owner steps.

## Phase 4 coordinated rollout

The total is now **ten migrations and eight Edge Functions**. The original seven are unchanged. New files `202610150008_message_privacy.sql`, `202610150009_device_access.sql` and `202610150010_privacy_preferences.sql` add retention/view-once policy, session approval and privacy controls. Review against the confirmed remote schema/history using the existing preflight/dry-run procedure. Migration 009 relocates existing client RPC implementations into private guarded functions while preserving public signatures/defaults; review remote custom functions before deployment. No data reset or historical E2EE conversion is performed.

Apply the reviewed schema first, then deploy **all** updated functions: `livekit-token`, `livekit-webhook`, `validate-media`, `delete-account`, `maintenance`, `dispatch-push`, **`view-once`**, **`device-security`**, **`call-control`**. User functions depend on `device_access_status`; the updated push worker depends on session-filtered token selection. Do not enable device approval before the complete coordinated rollout. The new functions validate Auth server-side with `verify_jwt=false` using the same established pattern; never expose service credentials to clients.

Keep the documented maintenance schedule running. It purges expired rows in batches, deletes queued objects through Storage and acknowledges deletion jobs only after success. Test backlog/failures, tombstones and process crashes in staging. Existing data remains under its previous message policy; profile/invitation defaults preserve prior visibility, and existing last-seen opt-outs seed the new online preference.

Device approval is opt-in, uses the signed JWT `session_id`, and requires current approved access plus fresh password proof for sensitive changes. It is not hardware attestation or E2EE key linking. A lost-all-approved-devices recovery procedure still needs owner identity verification and security review; no client self-approval bypass exists. Do not enable this protection on a real account until recovery and provider behavior have been exercised.

### Phase 4 staging privacy validation

`supabase/tests/hosted_privacy.ts` performs real Auth/DB/Storage/Edge requests using the existing ignored `config/hosted-test.json` fields and exact staging-target/write consent from HOSTED_TESTS.md. Its first three cases exercise policy snapshots and view-once opening/denial. It does not pretend to wait 24 hours or prove Android playback. For the device-activation cases, additionally set both `ALLOW_DEVICE_APPROVAL_ACTIVATION: true` and `DISPOSABLE_SECURITY_TEST_ACCOUNTS: true`, **only for throwaway accounts on a dedicated staging project**.

Activation is intentionally not undone by a client API. Cleanup revokes other test sessions and signs the clients out; the primary account may then require verified owner backend recovery/deletion before reuse. Do not run those cases against personal, shared or production accounts. No activation occurred in this environment.

```sh
deno run --config supabase/functions/deno.json \
  --allow-read=config/hosted-test.json,test/fixtures \
  --allow-write=docs/phase4-hosted-results.json \
  --allow-net=YOUR_PROJECT.supabase.co \
  supabase/tests/hosted_privacy.ts
```

Omit network permission and config to record an honest BLOCKED report. Exit codes are 0 PASS, 1 FAIL, 2 BLOCKED. Logs omit provider response bodies and credentials. The runner restores the prior conversation policy, soft-deletes its own messages and removes its upload where possible; tombstones, direct-conversation metadata, device-policy/audit rows and Auth accounts can remain. An unavailable cleanup is FAIL requiring owner review. App E2EE, actual native rendering, push delivery and calls remain separate tests.

## Phase 5 calling rollout

Read [PHASE5_CALLS.md](PHASE5_CALLS.md) before rollout. Drain active calls, confirm staging/schema/history, review migration `202610160011_advanced_calls.sql`, then deploy the full nine-function set, including the new `call-control`. Update clients, `livekit-token`, `livekit-webhook`, `dispatch-push` and `maintenance` together. Legacy client call identities/invitation state are not a mixed-version compatibility guarantee.

Configure signed LiveKit webhooks for `participant_joined`, `participant_left` and `room_finished`. Maintenance must run frequently to reconcile expired invitations, membership/device removal, 90-second recorded-media departure grace and durable epoch-specific eviction/room deletion. API failures remain queued; no immediate provider eviction guarantee exists. Initial LiveKit room tokens last 90 seconds, require accepted joined state and expose only approved track sources; established media requires teardown/worker enforcement.

Call FCM is high-priority data-only with an invitation deadline and a generic local notification. Install matching Firebase Android resources, deploy the updated sender and client together, and grant Android notification permission. Answer/reject actions require account/device/PIN validation; Answer still needs explicit confirmation before capture. Only one authorized registration is selected per invitation; multi-device calling remains disabled. Verify every background/terminated/force-stop scenario on actual devices; do not assume a push-send response proves delivery.

MediaProjection needs its new non-exported service/permission and explicit system consent. Default background relocking stops sharing on app switch; FLAG_SECURE can blank private app capture. PiP/Telecom/full-screen-intent privileges have not been added. See the exact Android/privacy limits and owner test procedure in the calling report.

## Phase 7 historical checkpoint

The owner reports a successful installed preview APK. Live backend activation and the connected APK are not verified. No selected staging reference, public URL/key, CLI/database access or disposable hosted-test accounts are available here. Review [PHASE7_ACTIVATION.md](PHASE7_ACTIVATION.md) before deploying; explicit owner confirmation is required after the exact remote target/history/schema and pending migrations are reviewed. No migrations/functions/workers were deployed in Phase 7. The Firebase console secret is owner-reported configured in GitHub and is not available to this process.

## Current connected configuration and local SQLite

The owner has supplied the public client pair for project `vjjvfshpzihbrdakbzct`. Ignored `config/connected-public.json`/`config/connected-build.json` select `LOCAL_UI_PREVIEW=false`; the existing preview config is unchanged. No public key is committed. Public-key presence is not a deployed-schema verification: the read-only settings check is blocked by proxy CONNECT 403, and privileged schema/migration access plus two disposable verified accounts are still missing. No remote changes were performed. The runtime local SQLite schema needs no Supabase migration; preserve/review the original 11 migrations/nine functions before an owner-approved remote rollout. [Storage, recovery and exact connected build steps](DATA_STORAGE.md).
