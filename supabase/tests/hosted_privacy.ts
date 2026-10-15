/** Real staging requests only. Missing configuration produces BLOCKED, not PASS.
 * Device approval activation additionally requires explicit opt-in on disposable
 * accounts: it is intentionally not disabled by cleanup. See DEPLOYMENT.md.
 */
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
const names = [
  "Expiration policy snapshot",
  "View-once atomic opening",
  "View-once Storage denial",
  "Unapproved second-device denial",
  "Recent-password device approval",
  "Revoked-device denial",
];
type State = "PASS" | "FAIL" | "BLOCKED";
const results: { scenario: string; status: State; detail: string }[] = [];
class Blocked extends Error {}
function check(value: unknown): asserts value {
  if (!value) throw Error("assertion");
}
async function op<T>(
  request: PromiseLike<{ data: T; error: unknown }>,
): Promise<T> {
  const { data, error } = await request;
  if (error) throw Error("request");
  return data;
}
async function step(name: string, action: () => Promise<void>) {
  try {
    await action();
    results.push({
      scenario: name,
      status: "PASS",
      detail: "Real staging backend requests completed",
    });
  } catch (error) {
    results.push({
      scenario: name,
      status: error instanceof Blocked ? "BLOCKED" : "FAIL",
      detail: error instanceof Blocked
        ? error.message
        : "Provider request/assertion failed; private responses suppressed",
    });
  }
}
let a: SupabaseClient | undefined,
  b: SupabaseClient | undefined,
  extra: SupabaseClient | undefined;
let config: Record<string, unknown> = {},
  cid: string | undefined,
  previousPolicy: number | undefined;
const owned: string[] = [];
let viewId: string | undefined, path: string | undefined;
let deviceActivation = false;
try {
  try {
    config = JSON.parse(await Deno.readTextFile("config/hosted-test.json"));
  } catch {
    throw new Blocked(
      "Needs ignored staging configuration and two verified disposable accounts",
    );
  }
  const url = String(config.SUPABASE_URL ?? ""),
    key = String(config.SUPABASE_ANON_KEY ?? "");
  const endpoint = new URL(url);
  check(
    endpoint.protocol === "https:" && endpoint.origin === url &&
      config.EXPECTED_SUPABASE_URL === url &&
      config.ALLOW_HOSTED_TEST_WRITES === true,
  );
  let publicKey = key.startsWith("sb_publishable_") && key.length > 25;
  if (!publicKey) {
    try {
      publicKey = JSON.parse(
        atob(key.split(".")[1].replaceAll("-", "+").replaceAll("_", "/")),
      ).role === "anon";
    } catch { /* reject */ }
  }
  check(publicKey && !key.startsWith("sb_secret_"));
  check(
    typeof config.TEST_A_EMAIL === "string" &&
      typeof config.TEST_B_EMAIL === "string" &&
      config.TEST_A_EMAIL !== config.TEST_B_EMAIL &&
      typeof config.TEST_A_PASSWORD === "string" &&
      typeof config.TEST_B_PASSWORD === "string",
  );
  a = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  b = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  check(
    !(await a.auth.signInWithPassword({
      email: config.TEST_A_EMAIL as string,
      password: config.TEST_A_PASSWORD as string,
    })).error,
  );
  check(
    !(await b.auth.signInWithPassword({
      email: config.TEST_B_EMAIL as string,
      password: config.TEST_B_PASSWORD as string,
    })).error,
  );
  const userA = (await a.auth.getUser()).data.user,
    userB = (await b.auth.getUser()).data.user;
  check(
    userA?.email_confirmed_at && userB?.email_confirmed_at &&
      userA.id !== userB.id,
  );
  cid = await op(a.rpc("create_direct", { peer: userB.id }));
  check(cid);
  const conversation = await op(
    a.from("conversations").select("disappearing_seconds").eq("id", cid)
      .single(),
  );
  check(conversation);
  previousPolicy = conversation.disappearing_seconds;
  await step(names[0], async () => {
    await op(a!.rpc("set_disappearing_policy", { cid, seconds: 86400 }));
    const mid = crypto.randomUUID();
    owned.push(mid);
    await op(
      a!.rpc("send_message", {
        cid,
        mid,
        content: "Disposable retention acceptance",
      }),
    );
    const message = await op(
      b!.from("messages").select("expires_at,created_at,expiration_seconds").eq(
        "id",
        mid,
      ).single(),
    );
    check(message);
    check(
      message.expiration_seconds === 86400 &&
        Date.parse(message.expires_at) - Date.parse(message.created_at) ===
          86400000,
    );
    // Wall-clock purge is covered by SQL tests; this does not pretend to wait a day.
  });
  await step(names[1], async () => {
    const bytes = await Deno.readFile("test/fixtures/hosted-pixel.png");
    path = `${cid}/${userA.id}/${crypto.randomUUID()}.png`;
    await op(
      a!.storage.from("chat-media").upload(path, bytes, {
        contentType: "image/png",
      }),
    );
    const validation = await a!.functions.invoke("validate-media", {
      body: { bucket: "chat-media", path },
    });
    check(!validation.error);
    viewId = crypto.randomUUID();
    owned.push(viewId);
    await op(
      a!.rpc("send_view_once_message", {
        cid,
        mid: viewId,
        media_kind: "image",
        attachment: { object_path: path, filename: "acceptance.png" },
      }),
    );
    const opening = await b!.functions.invoke("view-once", {
      body: { message_id: viewId },
    });
    check(!opening.error && opening.data instanceof Blob);
    const received = new Uint8Array(await opening.data.arrayBuffer());
    check(
      received.length === bytes.length &&
        received.every((value, index) => value === bytes[index]),
    );
    const again = await b!.functions.invoke("view-once", {
      body: { message_id: viewId },
    });
    check(again.error);
  });
  await step(names[2], async () => {
    if (!viewId || !path) {
      throw new Blocked("Needs the prior view-once upload/open");
    }
    const first = await a!.storage.from("chat-media").download(path),
      second = await b!.storage.from("chat-media").download(path);
    check(first.error && second.error);
  });
  // This activation changes the account's access policy. Ordinary hosted-test
  // consent is insufficient, and existing enabled accounts are not repurposed.
  const access = await op(a.rpc("device_access_status"));
  deviceActivation = config.ALLOW_DEVICE_APPROVAL_ACTIVATION === true &&
    config.DISPOSABLE_SECURITY_TEST_ACCOUNTS === true &&
    access.enforced === false;
  const requireActivation = () => {
    if (!deviceActivation) {
      throw new Blocked(
        "Needs explicit approval-activation consent on previously unenrolled disposable accounts",
      );
    }
  };
  let pending: { id: string; link_code: string } | undefined;
  await step(names[3], async () => {
    requireActivation();
    const enable = await a!.functions.invoke("device-security", {
      body: {
        action: "enable",
        password: config.TEST_A_PASSWORD,
        device_id: crypto.randomUUID(),
        name: "Staging acceptance primary",
      },
    });
    check(!enable.error);
    extra = createClient(url, key, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    check(
      !(await extra.auth.signInWithPassword({
        email: config.TEST_A_EMAIL as string,
        password: config.TEST_A_PASSWORD as string,
      })).error,
    );
    const request = await op(
      extra.rpc("request_device_approval", {
        device: crypto.randomUUID(),
        device_name: "Staging acceptance secondary",
      }),
    );
    pending = request.device;
    const rows = await op(
      extra.from("messages").select("id").eq("conversation_id", cid!),
    );
    check(rows && rows.length === 0);
    const rejected = await extra.rpc("send_message", {
      cid,
      mid: crypto.randomUUID(),
      content: "must be denied",
    });
    check(rejected.error);
  });
  await step(names[4], async () => {
    requireActivation();
    if (!pending || !extra) {
      throw new Blocked("Needs a pending secondary session");
    }
    const wrong = await a!.functions.invoke("device-security", {
      body: {
        action: "approve",
        password: config.TEST_A_PASSWORD,
        target: pending.id,
        code: "incorrect-code",
      },
    });
    check(wrong.error);
    const approval = await a!.functions.invoke("device-security", {
      body: {
        action: "approve",
        password: config.TEST_A_PASSWORD,
        target: pending.id,
        code: pending.link_code,
      },
    });
    check(!approval.error);
    const status = await op(extra.rpc("device_access_status"));
    check(status.authorized === true);
  });
  await step(names[5], async () => {
    requireActivation();
    if (!pending || !extra) throw new Blocked("Needs a secondary session");
    const revoke = await a!.functions.invoke("device-security", {
      body: {
        action: "revoke",
        password: config.TEST_A_PASSWORD,
        target: pending.id,
      },
    });
    check(!revoke.error);
    const status = await op(extra.rpc("device_access_status"));
    check(status.authorized === false);
    const denied = await extra.rpc("conversation_list");
    check(denied.error);
    const rows = await op(
      extra.from("messages").select("id").eq("conversation_id", cid!),
    );
    check(rows && rows.length === 0);
  });
} catch (error) {
  for (const scenario of names) {
    if (!results.some((result) => result.scenario === scenario)) {
      results.push({
        scenario,
        status: error instanceof Blocked ? "BLOCKED" : "FAIL",
        detail: error instanceof Blocked
          ? error.message
          : "Configuration/provider preflight failed; no private data logged",
      });
    }
  }
} finally {
  let cleanupFailed = false;
  if (a && cid) {
    if (previousPolicy !== undefined) {
      try {
        await op(
          a.rpc("set_disappearing_policy", { cid, seconds: previousPolicy }),
        );
      } catch {
        cleanupFailed = true;
      }
    }
    for (const mid of owned) {
      try {
        await op(a.rpc("delete_message", { mid }));
      } catch {
        cleanupFailed = true;
      }
    }
    if (path) {
      try {
        await op(a.storage.from("chat-media").remove([path]));
      } catch {
        cleanupFailed = true;
      }
    }
    if (deviceActivation) {
      try {
        const revoke = await a.functions.invoke("device-security", {
          body: { action: "revoke_others", password: config.TEST_A_PASSWORD },
        });
        if (revoke.error) cleanupFailed = true;
      } catch {
        cleanupFailed = true;
      }
    }
  }
  if (cleanupFailed) {
    results.push({
      scenario: "Run-owned cleanup",
      status: "FAIL",
      detail: "Owner review of disposable staging cleanup required",
    });
  }
  for (const client of [extra, b, a]) {
    if (client) await client.auth.signOut().catch(() => {});
  }
  await Deno.writeTextFile(
    "docs/phase4-hosted-results.json",
    JSON.stringify(
      {
        generated_at: new Date().toISOString(),
        scope: "real provider only; native/device E2EE not covered",
        device_approval_may_remain_enabled: deviceActivation,
        results,
      },
      null,
      2,
    ) + "\n",
  );
}
for (const result of results) {
  console.log(`${result.status}: ${result.scenario}`);
}
Deno.exit(
  results.some((result) => result.status === "FAIL")
    ? 1
    : results.some((result) => result.status === "BLOCKED")
    ? 2
    : 0,
);
