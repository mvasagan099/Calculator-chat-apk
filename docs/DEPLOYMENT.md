# Service deployment

Phase 1 defaults to a local preview without provider initialization. For connected mode set `LOCAL_UI_PREVIEW` to `false` in the public build configuration, as in `config/example.json`. No provider projects were supplied. These steps must be completed in accounts you control. Keep client identifiers and server credentials separate. Neither saving an environment draft nor building source provisions these services.

## Supabase

1. Create a Supabase project. Enable email confirmation, configure SMTP and password strength/rate limits, set a suitable email redirect policy and register `app.calculatorspace.calculator://auth-callback`. Set the site URL to a domain you control for email fallback. Android custom schemes are not domain-verified; for production configure a verified HTTPS Android App Link and update the redirect URI in both manifest and auth calls.
2. Before any migration or function deployment, confirm a dedicated **development/staging** project in the dashboard. Record its exact project ref and HTTPS origin. No target is currently configured in this checkout; do not infer a target from the local `project_id` label in `supabase/config.toml`. Use your own account to authenticate the official CLI and inspect the linked target:

   ```sh
   supabase projects list
   supabase link --project-ref CONFIRMED_STAGING_REF
   supabase migration list --linked
   supabase db push --linked --dry-run
   ```

   Run `supabase/remote_preflight.sql` in that project's SQL editor to inspect tables, RLS/policies, grants, publication and buckets without reading user data. Review the remote migration versions, schema and any naming conflicts against the seven local migrations. On an existing deployment, back up first and review function/policy replacements and data effects. Do not automatically repair migration history, reset a remote database, drop unknown objects or use `--include-all` to force mismatched history. Fresh migrations assume a compatible/new schema and do not backfill profiles for pre-existing Auth users. Resolve drift explicitly before applying anything. Then, only on the confirmed reviewed target:

   ```sh
   supabase login
   supabase link --project-ref CONFIRMED_STAGING_REF
   supabase db push
   ```

   This applies the seven versioned migrations. They create user-data tables, indexes, constraints, Auth profile trigger, RLS, private Storage buckets, authenticated RPCs, and Realtime publication entries. Review migrations before applying to an existing project. The application uses public profile discovery by username/public ID; email addresses are never in public profiles.
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
   ```

   `verify_jwt=false` is deliberate: user functions verify the supplied bearer using Auth `getUser`, supporting current Supabase signing keys; workers require `x-worker-secret`; the webhook verifies LiveKit's signature and body hash. There is no unauthenticated privileged entry point.
6. In Supabase Vault create `calculator_worker_url` = `https://PROJECT_REF.supabase.co/functions/v1/maintenance`, `calculator_push_url` = the `dispatch-push` URL, and `calculator_worker_secret` = the same worker secret. Enable Cron/pg_cron, pg_net and Vault. Run `supabase/schedule.sql` in the SQL editor. It schedules cleanup each minute and push dispatch every five seconds. Review worker responses in Cron/Edge logs without logging payloads or credentials. Verify a real expired status disappears from the database and Storage, rather than just being hidden on a client.
7. Put the project's HTTPS URL and **public publishable/anon** key in ignored `config/local.json`. No service-role credential goes into the APK.

Buckets reject oversize and unsupported MIME uploads. `validate-media` downloads with the user's token, checks file signatures/UTF-8 and records a server-only validation; message/status/profile writes require that validation. These checks are not malware scanning or full file-format sandboxing. Add a malware-scanning/quarantine pipeline if required for your release and never execute received files. Individual attachments are limited to 25 MB; avatars to 5 MB. Clients do not render HTML attachments.

Workers delete objects through the Storage API, not direct object-table deletes. They clean expired status media, soft-deleted media, old orphan uploads/avatars, stale push tokens, edit history and notification/rate-limit records. Normal messages are retained until a permitted deletion/account cleanup; edit-history retention is 30 days and old notification jobs seven days. Account deletion requires password reauthentication, removes owned media, erases authored message bodies, transfers lone-admin groups where possible and deletes the Auth user/profile with cascading user rows.

The default worker processes 50 notifications per batch, leases jobs and retries failed dispatch up to eight times. Monitor exhausted jobs. FCM has at-least-once delivery characteristics; the app uses stable notification tags for calls and the database uses unique recipient/resource jobs. High-volume deployments need worker concurrency/load testing and an operational dead-letter queue.

## Firebase Cloud Messaging

1. Create a Firebase project and Android app with package ID `app.calculatorspace.calculator_messenger`. If you change the package identity, update Android namespace, Kotlin package paths, Firebase registration and any auth app-link configuration together.
2. Enable the Firebase Cloud Messaging HTTP v1 API. Generate or bind a server service account with FCM send permission, then save its JSON as `FIREBASE_SERVICE_ACCOUNT` in Supabase secrets.
3. Download the Android console `google-services.json` to ignored `android/app/google-services.json` (this is public Android client metadata, never a server service-account JSON). Run the preparation command below with your public Supabase config. It verifies the exact Android package and extracts/compares Firebase app/project/sender/API identifiers, writes a separate public build config, and generates ignored `android/app/src/main/res/values/firebase_public.xml`. These resources let Android's FirebaseInitProvider initialize a terminated process before Dart runs. The Google Services Gradle plugin is not added; the supported resource values are generated directly.

   ```sh
   python3 scripts/prepare-client-config.py --mode connected \
     --input config/local.json --output config/build-public.json \
     --firebase-android android/app/google-services.json
   ./scripts/flutterw build apk --debug --dart-define-from-file=config/build-public.json
   ```

   `FIREBASE_API_KEY`, `FIREBASE_APP_ID`, `FIREBASE_SENDER_ID`, `FIREBASE_PROJECT_ID` may be omitted from local.json when they are derived from the console file. If supplied, they must agree with it. For Supabase-only testing, omit Firebase fields and the console argument. Public configuration and generated resources never contain a service-account private key. Firebase automatic registration is disabled in the manifest; the unlocked account explicitly registers after checking permission/preferences.
4. Verify the server FCM service-account `project_id` matches the Android console project, and verify the device has Google Play services. Open Settings → Notifications after signing in/unlocking. Grant Android's notification permission. Tokens are registered for the authenticated account, rotated using Firebase registration events, and removed on logout/disable. Confirm the actual token row exists without copying its value into logs.
5. Send messages/calls between the two test accounts. Verify worker jobs are marked sent, HTTP v1 sends succeed and notification channels are enabled. FCM payloads always say **Calculator / New activity** and contain only routing IDs. Android renders background/terminated notifications; Flutter renders foreground ones. No message content is fetched by the background isolate.

Notification delivery is best effort. Android force-stop prevents delivery until the user launches the app again; OEM battery restrictions can delay it. There is no attempt to bypass those restrictions or silently start microphone/camera capture. An incoming notification tap goes through unlock before the call can be answered. No full-screen incoming-call UI is requested while locked. Active calls request microphone/camera permission before capture, then start an explicit foreground service with a visible generic call notification and an End action. Cancellation invalidates pending connection steps; service cleanup and End actions are tied to a specific connection attempt so stale work cannot stop a newer call. Test foreground-service permission/start restrictions and microphone/camera behavior on each supported Android version.

## LiveKit

Use LiveKit Cloud or a supported self-hosted deployment with HTTPS/WSS, trusted TLS, UDP connectivity and TURN/TLS fallback. Configure LiveKit's advertised public addresses and firewall ports from its current deployment documentation. Supabase does not relay call media.

Save the server API key/secret only in Supabase. Configure the LiveKit webhook URL as `https://PROJECT_REF.supabase.co/functions/v1/livekit-webhook` with events including `room_finished`. Its receiver verifies the signed webhook. The token function calls `authorize_call`, which checks the existing participant, both current conversation memberships, blocks, call state and age, then issues a five-minute room-scoped token. Apply migration `202610150007_call_authorization.sql` before deploying the updated token function. A callee must accept before obtaining a token. Tokens are not an E2EE implementation and token expiry does not itself terminate an already connected participant.

Use short room empty/departure timeouts and monitor webhooks. The SQL worker marks unanswered ringing calls missed and caps accepted call metadata at two hours and closes ended LiveKit rooms through its server API; the webhook closes metadata when a room finishes. Test timeout, disconnect, cancellation, busy and reconnect paths. Group calling is deliberately excluded. Do not distribute until both physical devices can exchange real audio/video over Wi-Fi, mobile data and a TURN-only restrictive network.

## Cloud network requirements

This instance's network draft adds `storage.googleapis.com`, `maven.google.com`, `dl-ssl.google.com`, and `redirector.gvt1.com`, plus `api.github.com` for workflow status/artifact operations, to the existing package-manager presets. Saving that draft did not apply it: review/save in environment settings and publish through the product. The observed blocker is HTTP 403 on `storage.googleapis.com/download.flutter.io`; there were also transient 503s at Google's Maven repository. Preserve TLS and checksum verification. Retry the APK build after the network change applies.

For runtime testing, also allow your exact Supabase HTTPS/WSS hostname, LiveKit HTTPS/WSS hostname and applicable media/TURN destinations. Supabase workers need Google's `oauth2.googleapis.com` and `fcm.googleapis.com`, plus your LiveKit endpoint. These workers run in Supabase, not inside this Codex machine. No backend credentials currently exist in this environment.

## Current missing configuration

No authorized Supabase link, public URL/key, remote schema/history access, Firebase Android console config, FCM service account, LiveKit endpoint/key/secret, Cron/Vault worker secrets, verified disposable accounts or release keystore is available. No remote migration/function has been deployed. Put server secrets in Supabase, public identifiers in build configuration/GitHub repository variables, and test passwords only in ignored hosted-test configuration. See HOSTED_TESTS.md and PHASE2_VERIFICATION.md for exact blocked results and owner steps.
