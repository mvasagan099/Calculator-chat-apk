import test from "node:test";
import assert from "node:assert/strict";
import worker from "./account-auth-worker.mjs";
const env = {
  SUPABASE_URL: "https://example.supabase.co",
  SUPABASE_ANON_KEY: "public-fixture-key",
  ACCOUNT_AUTH_GATEWAY_SECRET: "S".repeat(64),
};
const input = { action: "login", user_id: "chosen_id", password: "fixture-password" };
function request(headers = {}) {
  return new Request("https://calculator-auth.workers.dev/account-auth", {
    method: "POST",
    headers: { "CF-Connecting-IP": "198.51.100.4", "content-type": "application/json", ...headers },
    body: JSON.stringify(input),
  });
}

test("proxy overrides spoofed IP and private secret and preserves optional user bearer", async () => {
  const originalFetch = globalThis.fetch;
  let upstream;
  globalThis.fetch = async (url, options) => {
    upstream = { url, options };
    return new Response(JSON.stringify({ user_uuid: "fixture" }), {
      status: 200, headers: { "content-type": "application/json" },
    });
  };
  try {
    const response = await worker.fetch(request({
      "x-trusted-account-ip": "8.8.8.8",
      "x-account-gateway-secret": "attacker",
      authorization: "Bearer user.jwt.token",
      "x-forwarded-for": "8.8.8.8",
    }), env);
    assert.equal(response.status, 200);
    assert.equal(upstream.url, "https://example.supabase.co/functions/v1/account-auth");
    assert.equal(upstream.options.headers.get("x-trusted-account-ip"), "198.51.100.4");
    assert.equal(upstream.options.headers.get("x-account-gateway-secret"), env.ACCOUNT_AUTH_GATEWAY_SECRET);
    assert.equal(upstream.options.headers.get("x-forwarded-for"), null);
    assert.equal(upstream.options.headers.get("authorization"), "Bearer user.jwt.token");
    assert.equal(JSON.parse(new TextDecoder().decode(upstream.options.body)).password, "fixture-password");
  } finally { globalThis.fetch = originalFetch; }
});

test("rejects missing Cloudflare client IP, malformed authorization and oversized bodies without forwarding", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = () => { throw Error("must not forward"); };
  try {
    assert.equal((await worker.fetch(request({ "CF-Connecting-IP": "" }), env)).status, 503);
    assert.equal((await worker.fetch(request({ authorization: "Invalid" }), env)).status, 401);
    const huge = new Request("https://calculator-auth.workers.dev/account-auth", {
      method: "POST", headers: { "CF-Connecting-IP": "192.0.2.1" },
      body: "x".repeat(8193),
    });
    assert.equal((await worker.fetch(huge, env)).status, 413);
    assert.equal((await worker.fetch(request(), { ...env, ACCOUNT_AUTH_GATEWAY_SECRET: "" })).status, 503);
  } finally { globalThis.fetch = originalFetch; }
});

test("only one known POST route is allowed", async () => {
  assert.equal((await worker.fetch(new Request("https://calculator-auth.workers.dev/account-auth"), env)).status, 405);
  assert.equal((await worker.fetch(new Request("https://calculator-auth.workers.dev/other"), env)).status, 404);
});
