# Phase 2 handoff: authenticated real-time messaging

Phase 1 is the default local UI mode. Its fixtures live only in `lib/features/preview/preview_fixtures.dart` and are never passed into `MessengerRepository` or a database request. Do not migrate these samples into user accounts.

## Existing foundation

- Supabase Flutter client initialization and public Dart defines: `lib/main.dart`, `lib/core/config/app_config.dart`.
- Account sign-in, verification/reset flow and secure session storage: `lib/core/services/auth_service.dart`, `lib/features/authentication`, `lib/core/security/session_storage.dart`.
- Account-bound device PIN gating, guarded routes and notification gating: `lib/core/router/app_router.dart`, `lib/core/security`, `lib/core/widgets`.
- Profiles/user discovery: `lib/features/contacts`, `lib/features/settings`.
- Real conversations, authenticated subscriptions, typed messages, encrypted cache and idempotent outbox: `lib/repositories/messenger_repository.dart`, `lib/models`, `lib/features/chats`, `lib/features/messaging`.
- Seven additive migration files and SQL security tests: `supabase/migrations`, `supabase/tests`.

These files were preserved from earlier development. They still need a real Supabase project and hosted acceptance testing. They are not a claim that Phase 2 has passed.

## Deployment sequence

1. Create a Supabase project in your account. Follow `DEPLOYMENT.md` to configure email confirmation, SMTP, redirects, Auth limits and private Realtime channels.
2. Review/apply the versioned migrations with the official Supabase CLI. Validate grants, RLS, profile creation and private Storage access in the deployed project.
3. Copy `config/example.json` to ignored `config/local.json`. Supply only your public project URL/publishable key and set `LOCAL_UI_PREVIEW` to `false`. Firebase defines can remain absent until notifications are configured; never put server secrets in this file.
4. Start the connected app. Register, verify email and sign in, then create a separate account-bound PIN. The local preview verifier uses `calculator.preview.pin.v1`; the connected verifier uses `calculator.pin.v1` plus an authenticated owner binding. Preview settings also use separate preference keys.
5. Create two disposable verified test accounts. Run the hosted integration test as documented in `TESTING.md`, using a separate ignored test configuration file. It verifies real authentication, subscription delivery, duplicate prevention, receipt updates and soft deletion.
6. Exercise two real Android devices: public-ID discovery, A→B/B→A delivery, cold/background relocking, authorized deep links, pagination, read-receipt privacy, offline/reconnect, blocking, logout and account isolation. A third account must fail unauthorized read/write attempts.
7. Investigate and fix provider/device failures before enabling media, LiveKit calls and FCM for broader release. No simulated transport result should replace real evidence.

## Unresolved prerequisites

This workspace has no Supabase, Firebase or LiveKit project configuration, no signing identity and no attached physical Android device. APK builds currently fail on the environment's HTTP 403 for the official Flutter artifact host. Apply the saved environment network settings and rerun both APK builds; confirm the actual output and signing certificate.

Do not introduce E2EE claims: the retained application uses TLS, RLS and private storage, without a reviewed end-to-end messaging protocol.
