# Supabase-only account authentication

This alternative needs **no Cloudflare Worker, new domain, or APK rebuild** (for the existing connected APK at commit 98df112). It is intended for the existing Supabase project and preserves the existing account-auth request protocol.

The Edge function no longer reads an unverified IP header. It enforces existing *atomic*, durable per-action/global and per-User-ID quotas through the private `account_auth_limit` RPC. Global signup is deliberately capped at **20 attempts/hour for the entire project**, other actions 100/hour, and per-ID caps remain 5 signup / 15 other attempts hourly. This is a tradeoff: without a trusted ingress, there is no reliable per-IP limiter. Malicious requests can consume the project-wide quota, and attacks spread over hours remain possible. Supabase Auth built-in throttling still applies. No claim is made that this matches verified source-IP rate limiting.

The Edge secret `ACCOUNT_RECOVERY_PEPPER` must exist and remain stable. `ACCOUNT_AUTH_IP_HEADER` is no longer read. `ACCOUNT_AUTH_ENABLED=false` continues to be the fail-closed default.

Activation sequence:
1. Confirm migration 012 schema, `private.account_auth_limits` and RPCs exist. Back up before changes; do not replay the historical setup SQL. Check Auth settings and reserved `.invalid` alias compatibility. The project currently has a pre-existing Auth user; don't delete or alter it.
2. Deploy only updated `supabase/functions/account-auth/index.ts` plus its original `_shared` dependencies. Keep `verify_jwt=false` as the existing handler handles bearer tokens for approved rotation and needs unauthenticated signup/login.
3. Check Edge logs for expected disabled HTTP 503, then, after reviewing the reduced quotas and user signup settings, explicitly set `ACCOUNT_AUTH_ENABLED=true` under Supabase → Edge Functions → Secrets. Supabase API enables new signups only when this value is exactly `true`; do not treat deployment alone as activation.
4. Test account signup/login with disposable test User IDs, confirm one-time recovery codes and PIN/device access. Verify unknown-user login is 401, rate limiting is 429, and no raw credentials or private provider errors appear in logs. An installed connected debug APK from 98df112 uses direct `account-auth`, so its client route need not change.
5. Keep `calculator-maintenance` and `calculator-push` schedules paused until separately verified. Verify provider-auth password behavior and security/advisors before public release.

**Security tradeoff:** For a publicly distributed app, a trusted source-IP gateway and stronger abuse controls are preferable. This Supabase-only route is reasonable for small closed testing with awareness of global denial-of-service from quota exhaustion. Never set infinite limits or accept caller-controlled forwarded headers.
