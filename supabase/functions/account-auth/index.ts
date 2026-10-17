import { createClient } from "@supabase/supabase-js";
import { adminClient, authenticated, body, HttpError, json, required, uuid } from "../_shared/http.ts";
import { AccountError, accountPassword, displayName, keyedHash, loginId, newAccountAlias, newRecoveryCodes, recoveryCode } from "../_shared/account_auth.ts";

const invalid = () => new AccountError(401, "invalid_credentials", "User ID or password is incorrect.");
const boundedFetch: typeof fetch = (url, options) => fetch(url, { ...options, signal: AbortSignal.timeout(15000) });
const publicClient = () => createClient(required("SUPABASE_URL"), required("SUPABASE_ANON_KEY"),
  { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: { fetch: boundedFetch } });

export const accountDependencies = {
  adminClient, authenticated, publicClient, required,
  enabled: () => Deno.env.get("ACCOUNT_AUTH_ENABLED") === "true",
};

export async function handleAccount(req: Request, dependencies = accountDependencies): Promise<Response> {
  const { adminClient, authenticated, publicClient, required, enabled } = dependencies;
  try {
    if (!enabled()) throw new HttpError(503, "Account service unavailable");
    const input = await body(req);
    const action = String(input.action);
    if (!["signup", "login", "recover", "rotate_codes"].includes(action)) throw new HttpError(400, "Invalid operation");
    const admin = adminClient(boundedFetch);
    const pepper = required("ACCOUNT_RECOVERY_PEPPER");
    // Deployment must strip/overwrite this header at its trusted ingress. Never
    // use a caller-supplied X-Forwarded-For chain as an authoritative client IP.
    const header = required("ACCOUNT_AUTH_IP_HEADER");
    const address = req.headers.get(header);
    if (!address || address.includes(",") || address.length > 128) throw new HttpError(503, "Trusted ingress required");
    const authorized = action === "rotate_codes" ? await authenticated(req) : null;
    const id = authorized?.user.id ?? loginId(input.user_id);
    for (const [scope, maximum] of [
      ["global:" + action, 100],
      ["ip:" + action + ":" + address, action === "signup" ? 5 : 30],
      ["id:" + action + ":" + id, action === "signup" ? 5 : 15],
    ] as const) {
      // The SQL limiter commits false results, so rejected attempts still count.
      const { data, error } = await admin.rpc("account_auth_limit", {
        scope_key: await keyedHash(pepper, "rate", scope), maximum,
      });
      if (error || data !== true) throw new AccountError(429, "rate_limited", "Too many attempts. Try again later.");
    }
    const codes = async () => await newRecoveryCodes(pepper);
    if (action === "rotate_codes") {
      const { user, client } = authorized!;
      const password = typeof input.password === "string" && input.password.length <= 256 ? input.password : "";
      if (!password || !user.email) throw invalid();
      const { error: limited } = await client.rpc("begin_device_security");
      if (limited) throw new AccountError(429, "rate_limited", "Security operation unavailable.");
      const proof = publicClient();
      const { data, error } = await proof.auth.signInWithPassword({ email: user.email, password });
      if (error || !data.session || data.user?.id !== user.id) throw invalid();
      try {
        const { data: access, error: accessError } = await client.rpc("device_access_status");
        if (accessError || !access?.authorized || !access.session_id) throw new HttpError(403, "Approved device required");
        const next = await codes();
        const { error: rotateError } = await admin.rpc("account_rotate_codes", { owner_id: user.id, sid: uuid(access.session_id), hashes: next.hashes });
        if (rotateError) throw new HttpError(409, "Recovery code update unavailable");
        return json({ recovery_codes: next.codes });
      } finally { await admin.auth.admin.signOut(data.session.access_token, "local"); }
    }
    const { data: target, error: lookupError } = await admin.rpc("account_login_target", { login_id: id });
    if (lookupError) throw new HttpError(503, "Account service unavailable");
    if (action === "signup") {
      const password = accountPassword(input.password, input.confirm_password ?? null);
      const name = displayName(input.username);
      if (target) throw new AccountError(409, "user_id_unavailable", "This User ID is unavailable.");
      const next = await codes();
      const intent = crypto.randomUUID();
      const alias = newAccountAlias();
      const { error: intentError } = await admin.rpc("account_signup_intent", {
        intent, login_id: id, display_name: name, hashes: next.hashes,
      });
      if (intentError) throw new HttpError(503, "Registration unavailable");
      let owner: string | undefined;
      try {
        // Admin-only email_confirm affects this synthetic identity, not global
        // Auth settings. No real address is accepted, requested or sent mail.
        const { data, error } = await admin.auth.admin.createUser({ email: alias, password, email_confirm: true,
          app_metadata: { calculator_signup_intent: intent } });
        if (!error && data.user) owner = data.user.id;
      } finally {
        await admin.rpc("account_discard_intent", { intent });
      }
      if (!owner) {
        const { data: occupied } = await admin.rpc("account_login_target", { login_id: id });
        if (occupied) throw new AccountError(409, "user_id_unavailable", "This User ID is unavailable.");
        throw new HttpError(503, "Registration unavailable. Try signing in before retrying.");
      }
      const { data, error } = await publicClient().auth.signInWithPassword({ email: alias, password });
      if (error || !data.session || data.user?.id !== owner) {
        // Do not delete a valid newly created account on a transient sign-in
        // failure. The owner can sign in and regenerate codes with their password.
        throw new AccountError(503, "account_created", "Account created. Sign in with your User ID and password, then save new recovery codes in Settings.");
      }
      return json({ refresh_token: data.session.refresh_token, user_uuid: owner, recovery_codes: next.codes });
    }
    if (action === "login") {
      if (typeof input.password !== "string" || input.password.length < 1 || input.password.length > 256) throw invalid();
      // Always perform a password verification, including unknown IDs. Random
      // dummy aliases avoid an account-existence fast path. Auth also rate limits.
      const alias = target?.alias ?? newAccountAlias();
      const { data, error } = await publicClient().auth.signInWithPassword({ email: alias, password: input.password });
      if (error || !target || !data.session || data.user?.id !== target.id) throw invalid();
      return json({ refresh_token: data.session.refresh_token, user_uuid: data.user.id });
    }
    const password = accountPassword(input.password, input.confirm_password ?? null);
    const code = recoveryCode(input.recovery_code);
    const device = uuid(input.device_id);
    const claim = crypto.randomUUID();
    const { data: owner, error: claimError } = await admin.rpc("account_claim_recovery", {
      login_id: id, code_hash: await keyedHash(pepper, "recovery", code), claim_id: claim,
    });
    if (claimError || !owner || !target || owner !== target.id) throw new AccountError(401, "invalid_recovery", "User ID or recovery code is invalid or already used.");
    const proof = publicClient();
    let completed = false;
    try {
      const { error: resetError } = await admin.auth.admin.updateUserById(owner, { password });
      if (resetError) throw new HttpError(503, "Recovery interrupted. Use another unused recovery code.");
      const { data, error } = await proof.auth.signInWithPassword({ email: target.alias, password });
      if (error || !data.session || data.user?.id !== owner) throw new HttpError(503, "Recovery interrupted. Use another unused recovery code.");
      // Revoke old refresh sessions at Auth as well as old access JWTs at RLS.
      const { error: revokeError } = await proof.auth.signOut({ scope: "others" });
      if (revokeError) throw new HttpError(503, "Session revocation unavailable");
      const { data: validated, error: userError } = await admin.auth.getUser(data.session.access_token);
      if (userError || validated.user?.id !== owner) throw invalid();
      const payload = JSON.parse(atob(data.session.access_token.split(".")[1].replaceAll("-", "+").replaceAll("_", "/")));
      const next = await codes();
      const { error: finishError } = await admin.rpc("account_finish_recovery", {
        owner_id: owner, claim_id: claim, sid: uuid(payload.session_id), device, hashes: next.hashes,
      });
      if (finishError) throw new HttpError(503, "Recovery interrupted. Use another unused recovery code.");
      completed = true;
      return json({ refresh_token: data.session.refresh_token, user_uuid: owner, recovery_codes: next.codes, recovered_device_id: device });
    } finally {
      if (!completed) {
        try { await proof.auth.signOut({ scope: "local" }); }
        finally { await admin.rpc("account_cancel_recovery", { owner_id: owner, claim_id: claim }); }
      }
    }
  } catch (error) {
    if (error instanceof AccountError) return json({ code: error.code, error: error.message }, error.status);
    if (error instanceof HttpError) return json({ error: error.message }, error.status);
    // Never serialize provider errors, request bodies, tokens or passwords.
    return json({ error: "Account service unavailable" }, 503);
  }
}
if (import.meta.main) Deno.serve((req) => handleAccount(req));
