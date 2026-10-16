# Hosted staging acceptance

`supabase/tests/hosted.ts` makes real Supabase Auth, PostgREST, Realtime, Storage and Edge Function requests. It contains no fake database operations. The run saved in [hosted-results.json](hosted-results.json) has **16 BLOCKED scenarios**, because there is no configured project or account. A type check is not evidence that hosted operations passed.

## Configure a dedicated staging project

Complete the target/schema/migration preflight in DEPLOYMENT.md first. Create two disposable, verified email/password accounts and enable read receipts. The runner preserves existing notification/status preferences; some tests block when the needed opt-in is absent. Tests may trigger generic notifications if workers and devices are already registered.

Create ignored `config/hosted-test.json` locally, with:

| Field | Value |
| --- | --- |
| `SUPABASE_URL` | Exact HTTPS staging project URL |
| `EXPECTED_SUPABASE_URL` | Same URL, independently checked against the dashboard |
| `SUPABASE_ANON_KEY` | Public publishable/anon key |
| `ALLOW_HOSTED_TEST_WRITES` | JSON boolean `true`, only after confirming the staging target |
| `TEST_A_EMAIL`, `TEST_A_PASSWORD` | Disposable verified account A |
| `TEST_B_EMAIL`, `TEST_B_PASSWORD` | Different disposable verified account B |
| `CREATE_TEST_ACCOUNTS` | Optional `true` for previously unused addresses; otherwise `false` |
| `TEST_CALL_SIGNALING` | Optional `true` only after confirming deployed LiveKit function/server secrets |

Never use real personal accounts, put test credentials in chat, or pass this file to `flutter build`. The public build-config validator rejects test/password fields. No service-role key is needed or accepted. With account creation enabled, email confirmation may block subsequent tests: confirm the emails, disable creation and rerun.

From the repository root:

```sh
deno run --config supabase/functions/deno.json \
  --allow-read=config/hosted-test.json,test/fixtures \
  --allow-write=docs/hosted-results.json \
  --allow-net=YOUR_PROJECT.supabase.co \
  supabase/tests/hosted.ts
```

Use the exact project hostname for HTTPS and WSS. In this cloud instance use `/workspace/toolchains/deno/node_modules/.bin/deno` with `DENO_DIR=/workspace/toolchains/deno-cache`. Without `--allow-net` and without a config file, the same runner can safely generate a BLOCKED report with no provider requests. Exit codes are **0** (no failure/blocker), **1** (assertion/provider failure), **2** (one or more blocked checks). Skipped signup using preverified accounts is explicitly NOT TESTED. Logs suppress raw provider errors, messages, email addresses, tokens and passwords.

## Coverage and limits

The runner checks verified login/profile creation; username/public-ID discovery; A→B and B→A durable and Realtime delivery; idempotent sending; delivered and read receipt updates including Realtime; valid image and voice-file upload, server validation and byte-for-byte authorized download; group invitation/messaging; unauthorized read/write denial; block enforcement; contact-scoped statuses and view tracking. Optional call checks require migration 011 and updated call-control/token functions, and exercise real server tokens, 90-second TTL and per-join identity/source claims, acceptance, ending, history and token denial. They do **not** establish a WebRTC media connection or verify the token signature at a LiveKit media server.

The original fixtures are a valid generated 1×1 PNG and a 0.5-second 440 Hz Opus tone, decoded/inspected locally with ffprobe. Tone delivery is not microphone recording or device playback evidence. Flutter media compression/rendering and Android permission behavior require device tests.

Voice/video media, foreground/background/terminated notifications and Android unlock behavior remain BLOCKED in this runner. Run these on two real authenticated devices and record separate evidence. Never convert a token or database success into a voice/video PASS.

Cleanup attempts every run-owned message, object, group, status and call, and removes only contacts/blocks it inserted. A failed cleanup is FAIL and requires owner review. Message soft-delete tombstones, the direct conversation, notification jobs and Auth identities may remain for normal retention/owner cleanup. Signup-created accounts are not automatically deleted. This is why a disposable staging project is required.

## Phase 7 rerun

The current `hosted-results.json` was regenerated with the real runner: **16 BLOCKED**, exit 2, because no staging/test configuration exists. No network permission or provider writes were granted for that blocked run. All 11 migrations pass the separate local SQL suites; no remote migration state can be inferred from that. Preview APK build/installation is owner-reported successful and is not evidence for these hosted scenarios. See [PHASE7_ACTIVATION.md](PHASE7_ACTIVATION.md).
