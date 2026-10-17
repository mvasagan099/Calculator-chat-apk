// Cloudflare Workers ingress for Calculator Messenger no-email account actions.
// Bindings are private Worker secrets/config. Never log request bodies or headers.
const LIMIT_BYTES = 8192;
function unavailable(status = 503) {
  return new Response(JSON.stringify({ error: "Account operation unavailable" }), {
    status, headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== "/account-auth" || url.search) return unavailable(404);
    if (request.method !== "POST") return unavailable(405);
    const ip = request.headers.get("CF-Connecting-IP");
    // Cloudflare supplies CF-Connecting-IP on the original inbound Worker
    // request; NEVER use user-supplied x-real-ip or x-forwarded-for.
    if (!ip || ip.includes(",") || ip.length > 128) return unavailable();
    const secret = env.ACCOUNT_AUTH_GATEWAY_SECRET;
    const anonKey = env.SUPABASE_ANON_KEY;
    const origin = env.SUPABASE_URL;
    if (typeof secret !== "string" || secret.length < 32 ||
        typeof anonKey !== "string" || !anonKey ||
        typeof origin !== "string") return unavailable();
    let upstreamUrl;
    try {
      const originUrl = new URL(origin);
      if (originUrl.protocol !== "https:" || !originUrl.hostname ||
          originUrl.pathname !== "/" || originUrl.search || originUrl.hash ||
          originUrl.username || originUrl.password) return unavailable();
      upstreamUrl = originUrl.origin + "/functions/v1/account-auth";
    } catch { return unavailable(); }

    const declared = Number(request.headers.get("content-length") ?? "0");
    if (!Number.isFinite(declared) || declared > LIMIT_BYTES) return unavailable(413);
    let payload;
    try {
      payload = await request.arrayBuffer();
    } catch { return unavailable(400); }
    if (payload.byteLength === 0 || payload.byteLength > LIMIT_BYTES) return unavailable(413);

    const authorization = request.headers.get("authorization");
    if (authorization && (authorization.length > 8192 ||
        !/^Bearer [A-Za-z0-9._~+/-]+={0,2}$/i.test(authorization))) return unavailable(401);
    const headers = new Headers({
      "content-type": "application/json",
      "apikey": anonKey,
      "x-account-gateway-secret": secret,
      "x-trusted-account-ip": ip,
      ...(authorization ? { authorization } : {}),
    });
    try {
      const response = await fetch(upstreamUrl, {
        method: "POST", headers, body: payload, redirect: "manual",
      });
      if (response.status < 200 || response.status > 599 || response.status >= 300 && response.status < 400) return unavailable();
      if (!(response.headers.get("content-type") ?? "").includes("application/json")) return unavailable();
      const reply = await response.text();
      if (reply.length > 65536) return unavailable();
      return new Response(reply, {
        status: response.status,
        headers: { "content-type": "application/json", "cache-control": "no-store" },
      });
    } catch { return unavailable(); }
  },
};
