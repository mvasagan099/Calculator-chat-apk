import { accountPassword, displayName, keyedHash, loginId, newAccountAlias, newRecoveryCodes, recoveryCode } from "./account_auth.ts";
import { handleAccount, accountDependencies } from "../account-auth/index.ts";

function assert(value: unknown, message = "assertion failed"): asserts value { if (!value) throw new Error(message); }
function rejects(action: () => unknown) { try { action(); } catch { return; } throw new Error("invalid input accepted"); }
const password = "a-long-fixture-password";
const owner = "12000000-0000-0000-0000-000000000001";
const sessionId = "12000000-0000-0000-0000-000000000002";
const pepper = "fixture-pepper-never-a-production-secret";
type Identity = { id: string; alias: string; password: string };

function fixture() {
  const users = new Map<string, Identity>();
  const intents = new Map<string, Record<string, unknown>>();
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  const created: { email: string; email_confirm: boolean }[] = [];
  const loginAliases: string[] = [];
  let limited = false, approved = true, passwordFailure = false, wrongOwner = false;
  let claimUsed = false;
  let proofSignouts = 0;
  const rpc = async (name: string, args: Record<string, unknown> = {}) => {
    calls.push({ name, args });
    if (name === "account_auth_limit") return { data: !limited, error: null };
    if (name === "account_login_target") { const u = users.get(String(args.login_id)); return { data: u ? { id: u.id, alias: u.alias } : null, error: null }; }
    if (name === "account_signup_intent") intents.set(String(args.intent), args);
    if (name === "account_discard_intent") intents.delete(String(args.intent));
    if (name === "device_access_status") return { data: { authorized: approved, session_id: sessionId }, error: null };
    if (name === "account_claim_recovery") {
      if (claimUsed || args.code_hash !== await keyedHash(pepper, "recovery", "a".repeat(64))) return { data: null, error: null };
      claimUsed = true; return { data: owner, error: null };
    }
    return { data: null, error: null };
  };
  const admin = {
    rpc,
    auth: {
      getUser: () => Promise.resolve({ data: { user: { id: owner } }, error: null }),
      admin: {
        createUser: async (input: { email: string; email_confirm: boolean; password: string; app_metadata: { calculator_signup_intent: string } }) => {
          created.push({ email: input.email, email_confirm: input.email_confirm });
          const intent = intents.get(input.app_metadata.calculator_signup_intent)!;
          await Promise.resolve();
          if (users.has(String(intent.login_id))) return { data: { user: null }, error: new Error("duplicate") };
          users.set(String(intent.login_id), { id: owner, alias: input.email, password: input.password });
          return { data: { user: { id: owner } }, error: null };
        },
        updateUserById: async (_id: string, input: { password: string }) => {
          if (passwordFailure) return { error: new Error("private provider detail") };
          users.get("chosen_id")!.password = input.password;
          return { error: null };
        },
        signOut: () => { proofSignouts++; return Promise.resolve({ error: null }); },
      },
    },
  };
  const proof = { auth: {
    signInWithPassword: (input: { email: string; password: string }) => {
      loginAliases.push(input.email);
      const found = [...users.values()].find((u) => u.alias === input.email && u.password === input.password);
      const token = "header." + btoa(JSON.stringify({ session_id: sessionId })) + ".signature";
      return Promise.resolve({ data: { user: found ? { id: wrongOwner ? "other" : found.id } : null,
        session: found ? { access_token: token, refresh_token: "fixture-refresh" } : null }, error: found ? null : new Error("private provider detail") });
    },
    signOut: () => { proofSignouts++; return Promise.resolve({ error: null }); },
  } };
  const dependencies = {
    enabled: () => true,
    required: (key: string) => {
      if (key === "ACCOUNT_RECOVERY_PEPPER") return pepper;

      throw new Error("Unexpected configuration requirement: " + key);
    },
    adminClient: () => admin, publicClient: () => proof,
    authenticated: async () => {
      if (!approved) throw new Error("not approved");
      return { user: { id: owner, email: users.get("chosen_id")?.alias }, client: { rpc }, admin };
    },
  } as unknown as typeof accountDependencies;
  const request = (input: Record<string, unknown>, headers = { "x-trusted-ip": "192.0.2.1" }) =>
    handleAccount(new Request("https://fixture.invalid", { method: "POST", headers, body: JSON.stringify(input) }), dependencies);
  const seed = () => users.set("chosen_id", { id: owner, alias: "random@accounts.owner-domain.net", password });
  return { request, seed, users, calls, intents, created, loginAliases, setLimited: () => limited = true,
    denyDevice: () => approved = false, failPassword: () => passwordFailure = true,
    wrongOwner: () => wrongOwner = true, signouts: () => proofSignouts };
}

Deno.test("account input: strict User IDs, Unicode display names, confirmation and password bounds", () => {
  assert(loginId("chosen_id") === "chosen_id"); assert(displayName(" மணிவாசகன் ") === "மணிவாசகன்");
  for (const id of ["ab", "UPPER", "name@example.com", "../x", "a".repeat(31)]) rejects(() => loginId(id));
  for (const name of [" ", "a".repeat(81)]) rejects(() => displayName(name));
  rejects(() => accountPassword("short", "short")); rejects(() => accountPassword(password, "different"));
  rejects(() => accountPassword("a".repeat(257))); accountPassword(password, password);
  rejects(() => recoveryCode("short"));
});
Deno.test("internal aliases: unique server-generated UUIDs use only reserved .invalid", () => {
  const aliases = Array.from({ length: 128 }, () => newAccountAlias());
  assert(new Set(aliases).size === aliases.length);
  assert(aliases.every((alias) => /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}@calculator-messenger\.invalid$/.test(alias)));
});
Deno.test("signup: no domain configuration, caller email ignored, synthetic identity confirmed server-side", async () => {
  const f = fixture();
  const response = await f.request({ action: "signup", user_id: "chosen_id", username: "Name", password, confirm_password: password,
    email: "untrusted@example.com", alias: "chosen_id@untrusted.example", alias_domain: "untrusted.example" });
  assert(response.status === 200 && f.created.length === 1);
  assert(f.created[0].email.endsWith("@calculator-messenger.invalid") && f.created[0].email_confirm === true);
  assert(!f.created[0].email.includes("chosen_id") && !f.created[0].email.includes("untrusted"));
  const login = await f.request({ action: "login", user_id: "chosen_id", password });
  assert(login.status === 200 && f.loginAliases.at(-1) === f.created[0].email);
});
Deno.test("login: unknown IDs use a fresh reserved dummy alias; legacy alias is unchanged", async () => {
  const f = fixture(); f.seed();
  const legacy = f.users.get("chosen_id")!.alias;
  assert((await f.request({ action: "login", user_id: "unknown_id", password })).status === 401);
  assert(f.loginAliases.at(-1)!.endsWith("@calculator-messenger.invalid"));
  assert((await f.request({ action: "login", user_id: "chosen_id", password })).status === 200);
  assert(f.loginAliases.at(-1) === legacy && f.users.get("chosen_id")!.alias === legacy);
});
Deno.test("recovery: eight unique random codes, domain-separated keyed hashes", async () => {
  const next = await newRecoveryCodes(pepper);
  assert(new Set(next.codes).size === 8 && next.hashes.length === 8);
  assert(next.codes.every((c) => /^[a-f0-9]{64}$/.test(c)));
  assert(next.hashes[0] !== next.codes[0]);
  assert(await keyedHash(pepper, "rate", next.codes[0]) !== next.hashes[0]);
});
Deno.test("signup: immediate Auth session and chosen ID/name; no password in DB RPCs", async () => {
  const f = fixture(); const r = await f.request({ action: "signup", user_id: "chosen_id", username: "Chosen name", password, confirm_password: password });
  const data = await r.json(); assert(r.status === 200 && data.refresh_token && data.user_uuid === owner);
  assert(data.recovery_codes.length === 8 && f.users.has("chosen_id") && f.intents.size === 0);
  assert(!JSON.stringify(f.calls).includes(password));
  assert(f.calls.some((c) => c.name === "account_signup_intent" && c.args.display_name === "Chosen name"));
});
Deno.test("signup: confirmation mismatch and weak passwords never create an Auth user", async () => {
  const f = fixture();
  for (const [pw, confirm] of [["short", "short"], [password, "other"]]) {
    const r = await f.request({ action: "signup", user_id: "chosen_id", username: "Name", password: pw, confirm_password: confirm });
    assert(r.status === 400 && f.users.size === 0 && f.intents.size === 0);
  }
});
Deno.test("signup: duplicate ID and racing requests create one identity", async () => {
  const f = fixture(); const input = { action: "signup", user_id: "chosen_id", username: "Name", password, confirm_password: password };
  const results = await Promise.all([f.request(input), f.request(input)]);
  assert(results.map((r) => r.status).sort().join() === "200,409");
  assert(f.users.size === 1 && f.intents.size === 0);
  assert((await f.request(input)).status === 409);
});
Deno.test("login: legacy and new User IDs work repeatedly without email input", async () => {
  const f = fixture(); f.seed();
  for (let i = 0; i < 2; i++) {
    const r = await f.request({ action: "login", user_id: "chosen_id", password });
    assert(r.status === 200 && (await r.json()).user_uuid === owner);
  }
});
Deno.test("login: unknown User ID and bad password return identical safe errors", async () => {
  const f = fixture(); f.seed();
  const a = await f.request({ action: "login", user_id: "unknown_id", password });
  const b = await f.request({ action: "login", user_id: "chosen_id", password: "bad" });
  assert(a.status === 401 && b.status === 401 && await a.text() === await b.text());
});
Deno.test("login: provider session must belong to resolved UUID", async () => {
  const f = fixture(); f.seed(); f.wrongOwner();
  assert((await f.request({ action: "login", user_id: "chosen_id", password })).status === 401);
});
Deno.test("rate limits and trusted ingress fail closed before credential verification", async () => {
  const f = fixture(); f.seed(); f.setLimited();
  assert((await f.request({ action: "login", user_id: "chosen_id", password })).status === 429);
  assert((await f.request({ action: "login", user_id: "chosen_id", password }, {} as { "x-trusted-ip": string })).status === 429);
});
Deno.test("recovery: consume proof, revoke other sessions, bind fresh device and rotate codes", async () => {
  const f = fixture(); f.seed(); const input = { action: "recover", user_id: "chosen_id", recovery_code: "a".repeat(64), password, confirm_password: password, device_id: sessionId };
  const r = await f.request(input); const data = await r.json();
  assert(r.status === 200 && data.recovered_device_id === sessionId && data.recovery_codes.length === 8);
  assert(f.calls.some((c) => c.name === "account_finish_recovery" && c.args.owner_id === owner));
  assert(f.signouts() > 0 && (await f.request(input)).status === 401);
});
Deno.test("recovery: wrong code cannot reset password; failure cancels only its own claim", async () => {
  const f = fixture(); f.seed();
  const input = { action: "recover", user_id: "chosen_id", recovery_code: "b".repeat(64), password, confirm_password: password, device_id: sessionId };
  assert((await f.request(input)).status === 401);
  assert(!f.calls.some((c) => c.name === "account_finish_recovery"));
  f.failPassword(); const r = await f.request({ ...input, recovery_code: "a".repeat(64) });
  assert(r.status === 503 && !(await r.text()).includes("private provider detail"));
  assert(f.calls.some((c) => c.name === "account_cancel_recovery" && c.args.owner_id === owner));
});
Deno.test("rotation: password proof and approved device required; proof session is cleaned", async () => {
  const f = fixture(); f.seed();
  const r = await f.request({ action: "rotate_codes", password });
  assert(r.status === 200 && (await r.json()).recovery_codes.length === 8 && f.signouts() === 1);
  f.denyDevice(); assert((await f.request({ action: "rotate_codes", password })).status !== 200);
});

Deno.test("Supabase-only: absent/spoofed IP never changes durable limiter scopes", async () => {
  const f = fixture();
  const input = { action: "login", user_id: "chosen_id", password };
  await f.request(input, {});
  await f.request(input, { "x-trusted-ip": "1.2.3.4", "x-forwarded-for": "8.8.8.8" } as unknown as { "x-trusted-ip": string });
  assert(f.calls.filter((call) => call.name === "account_auth_limit").length === 4);
  const scopes = f.calls.filter((call) => call.name === "account_auth_limit")
    .map((call) => call.args.scope_key);
  assert(scopes.length === 4 && scopes[0] === scopes[2] && scopes[1] === scopes[3]);
});
