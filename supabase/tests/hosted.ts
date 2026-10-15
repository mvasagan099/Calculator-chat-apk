/** Real-provider staging acceptance. No admin keys, mocks or automatic deployment.
 * Input: ignored config/hosted-test.json. Output: sanitized evidence JSON.
 * See docs/HOSTED_TESTS.md for explicit write consent and cleanup limitations.
 */
import {
  createClient,
  FunctionsHttpError,
  type SupabaseClient,
} from "@supabase/supabase-js";

type State = "PASS" | "FAIL" | "BLOCKED" | "NOT TESTED";
type Result = { scenario: string; status: State; detail: string };
type Config = Record<string, unknown>;
class Blocked extends Error {}
const results: Result[] = [];
const required = [
  "User A signs up",
  "User B signs up",
  "User A finds User B",
  "User A sends a message",
  "User B receives the message",
  "User B replies",
  "Delivery and read-state updates",
  "Image upload and download",
  "Audio message delivery",
  "Group creation and messaging",
  "Unauthorized database reads and writes rejected",
  "Blocked interactions rejected",
  "Voice media connects",
  "Video media connects",
  "Notifications reach background devices",
  "Android unlock protection remains enforced",
];
const record = (scenario: string, status: State, detail: string) => {
  results.push({ scenario, status, detail });
  console.log(`${status}: ${scenario}`);
};
async function step(scenario: string, action: () => Promise<void>) {
  try {
    await action();
    record(scenario, "PASS", "Real staging provider checks completed");
  } catch (e) {
    record(
      scenario,
      e instanceof Blocked ? "BLOCKED" : "FAIL",
      e instanceof Blocked
        ? e.message
        : "Provider request/assertion failed; no private response was logged",
    );
  }
}
function accessDenied(error: unknown) {
  return error instanceof FunctionsHttpError && error.context.status === 403;
}
function check(condition: unknown): asserts condition {
  if (!condition) throw new Error("Assertion failed");
}
async function op<T>(
  request: PromiseLike<{ data: T; error: unknown }>,
): Promise<T> {
  const result = await request;
  if (result.error) throw new Error("Provider operation failed");
  return result.data;
}
async function value<T>(
  request: PromiseLike<{ data: T; error: unknown }>,
): Promise<NonNullable<T>> {
  const data = await op(request);
  if (data === null || data === undefined) {
    throw new Error("Required provider data missing");
  }
  return data as NonNullable<T>;
}
function deadline<T>(promise: Promise<T>): Promise<T> {
  let timer: ReturnType<typeof setTimeout>;
  return Promise.race([
    promise,
    new Promise<T>((_, reject) => {
      timer = setTimeout(() => reject(new Error("Realtime timeout")), 20000);
    }),
  ]).finally(() => clearTimeout(timer));
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}
function publicKey(key: string) {
  if (key.startsWith("sb_publishable_") && key.length > 25) return true;
  try {
    const payload = key.split(".")[1].replaceAll("-", "+").replaceAll("_", "/");
    return JSON.parse(
      atob(payload.padEnd(Math.ceil(payload.length / 4) * 4, "=")),
    ).role === "anon";
  } catch {
    return false;
  }
}
async function run(config: Config) {
  const url = String(config.SUPABASE_URL ?? "");
  const key = String(config.SUPABASE_ANON_KEY ?? "");
  const inputs = [
    "TEST_A_EMAIL",
    "TEST_A_PASSWORD",
    "TEST_B_EMAIL",
    "TEST_B_PASSWORD",
  ];
  if (
    !url.startsWith("https://") || url !== config.EXPECTED_SUPABASE_URL ||
    !publicKey(key) || config.ALLOW_HOSTED_TEST_WRITES !== true ||
    inputs.some((name) => typeof config[name] !== "string" || !config[name]) ||
    config.TEST_A_EMAIL === config.TEST_B_EMAIL
  ) {
    for (const scenario of required) {
      record(
        scenario,
        "BLOCKED",
        "Needs a confirmed staging URL, public key, two distinct test accounts and explicit ALLOW_HOSTED_TEST_WRITES consent",
      );
    }
    return;
  }
  const options = {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
    global: {
      fetch: (input: RequestInfo | URL, init?: RequestInit) =>
        fetch(input, {
          ...init,
          signal: init?.signal
            ? AbortSignal.any([init.signal, AbortSignal.timeout(15000)])
            : AbortSignal.timeout(15000),
        }),
    },
  };
  const a = createClient(url, key, options),
    b = createClient(url, key, options),
    anonymous = createClient(url, key, options);
  let uidA: string | undefined,
    uidB: string | undefined,
    cid: string | undefined;
  const messages: { client: SupabaseClient; id: string }[] = [];
  const objects: string[] = [],
    groups: string[] = [],
    statuses: string[] = [],
    calls: string[] = [];
  const channels: {
    client: SupabaseClient;
    channel: ReturnType<SupabaseClient["channel"]>;
  }[] = [];
  let insertedContact = false, insertedBlock = false;
  const midA = crypto.randomUUID(), midB = crypto.randomUUID();
  const receivedA = deferred<Record<string, unknown>>(),
    receivedB = deferred<Record<string, unknown>>();
  const readA = deferred<void>(), readB = deferred<void>();
  const ready = () => {
    if (!uidA || !uidB) {
      throw new Blocked("Two verified staging logins are required");
    }
  };
  const conversation = () => {
    ready();
    if (!cid) throw new Blocked("Direct conversation setup did not pass");
    return cid;
  };
  async function watch(
    client: SupabaseClient,
    incoming: string,
    outgoing: string,
    received: ReturnType<typeof deferred<Record<string, unknown>>>,
    read: ReturnType<typeof deferred<void>>,
  ) {
    const subscribed = deferred<void>();
    const channel = client.channel(`hosted-${crypto.randomUUID()}`)
      .on("postgres_changes", {
        event: "INSERT",
        schema: "public",
        table: "messages",
        filter: `conversation_id=eq.${cid}`,
      }, (event) => {
        if (event.new.id === incoming) received.resolve(event.new);
      })
      .on("postgres_changes", {
        event: "*",
        schema: "public",
        table: "message_receipts",
        filter: `message_id=eq.${outgoing}`,
      }, (event) => {
        const row = event.new as Record<string, unknown>;
        if (row.read_at) read.resolve();
      }).subscribe((state) => {
        if (state === "SUBSCRIBED") subscribed.resolve();
      });
    channels.push({ client, channel });
    await deadline(subscribed.promise);
  }
  async function send(
    client: SupabaseClient,
    id: string,
    text: string,
    target = conversation(),
    kind = "text",
    attachment?: Record<string, unknown>,
  ) {
    await value(
      client.rpc("send_message", {
        cid: target,
        mid: id,
        content: text,
        message_kind: kind,
        ...(attachment ? { attachment } : {}),
      }),
    );
    messages.push({ client, id });
  }
  async function media(file: string, mime: string, kind: string) {
    const target = conversation();
    const bytes = await Deno.readFile(file);
    const path = `${target}/${uidA}/${crypto.randomUUID()}-${
      file.split("/").at(-1)
    }`;
    await value(
      a.storage.from("chat-media").upload(path, bytes, {
        contentType: mime,
        upsert: false,
      }),
    );
    objects.push(path);
    await value(
      a.functions.invoke("validate-media", {
        body: { bucket: "chat-media", path },
      }),
    );
    const id = crypto.randomUUID();
    await send(a, id, "Hosted media acceptance fixture", target, kind, {
      object_path: path,
      filename: file.split("/").at(-1),
      mime_type: mime,
      size_bytes: bytes.length,
    });
    const rows = await value(
      b.from("messages").select("id,kind,message_attachments(object_path)").eq(
        "id",
        id,
      ),
    );
    check(rows.length === 1 && rows[0].kind === kind);
    const blob = await value(b.storage.from("chat-media").download(path));
    const downloaded = new Uint8Array(await blob.arrayBuffer());
    check(
      downloaded.length === bytes.length &&
        downloaded.every((byte, i) => byte === bytes[i]),
    );
  }
  try {
    for (const [client, who] of [[a, "A"], [b, "B"]] as const) {
      const scenario = `User ${who} signs up`;
      if (config.CREATE_TEST_ACCOUNTS !== true) {
        record(
          scenario,
          "NOT TESTED",
          "Using owner-created verified staging accounts; signup/email verification must be tested separately",
        );
      } else {
        await step(scenario, async () => {
          const { data, error } = await client.auth.signUp({
            email: String(config[`TEST_${who}_EMAIL`]),
            password: String(config[`TEST_${who}_PASSWORD`]),
          });
          check(!error && data.user && data.user.identities?.length);
          if (!data.session) {
            throw new Blocked(
              "Signup accepted; complete email verification in the test mailbox, then rerun using existing accounts",
            );
          }
        });
      }
      await step(`User ${who} authenticated login and profile`, async () => {
        const { data, error } = await client.auth.signInWithPassword({
          email: String(config[`TEST_${who}_EMAIL`]),
          password: String(config[`TEST_${who}_PASSWORD`]),
        });
        if (error?.code === "email_not_confirmed") {
          throw new Blocked("Verify the staging account email first");
        }
        check(!error && data.user);
        const profile = await value(
          client.from("profiles").select("id,username,public_id").eq(
            "id",
            data.user.id,
          ).single(),
        );
        check(
          profile.id === data.user.id && profile.username && profile.public_id,
        );
        if (who === "A") uidA = data.user.id;
        else uidB = data.user.id;
      });
    }
    await step(required[2], async () => {
      ready();
      const peer = await value(
        b.from("profiles").select("username,public_id").eq("id", uidB!)
          .single(),
      );
      const found = await value(
        a.from("profiles").select("id").eq("username", peer.username).eq(
          "public_id",
          peer.public_id,
        ).single(),
      );
      check(found.id === uidB);
      cid = await value(a.rpc("create_direct", { peer: uidB }));
      await watch(a, midB, midA, receivedA, readA);
      await watch(b, midA, midB, receivedB, readB);
    });
    await step(required[3], async () => {
      const target = conversation();
      await send(a, midA, "Hosted A to B acceptance", target);
      await value(
        a.rpc("send_message", {
          cid: target,
          mid: midA,
          content: "Hosted A to B acceptance",
        }),
      );
      const rows = await value(a.from("messages").select("id").eq("id", midA));
      check(rows.length === 1);
    });
    await step(required[4], async () => {
      conversation();
      const event = await deadline(receivedB.promise);
      check(event.id === midA && event.sender_id === uidA);
      const rows = await value(
        b.from("messages").select("id,body").eq("id", midA),
      );
      check(rows.length === 1 && rows[0].body === "Hosted A to B acceptance");
    });
    await step(required[5], async () => {
      await send(b, midB, "Hosted B to A reply");
      const event = await deadline(receivedA.promise);
      check(event.id === midB && event.sender_id === uidB);
      check(
        (await value(a.from("messages").select("id").eq("id", midB))).length ===
          1,
      );
    });
    await step(required[6], async () => {
      const target = conversation();
      for (const client of [a, b]) {
        const settings = await value(
          client.from("user_settings").select("read_receipts").eq(
            "user_id",
            client === a ? uidA! : uidB!,
          ).single(),
        );
        if (!settings.read_receipts) {
          throw new Blocked(
            "Enable read receipts for these disposable accounts before the read-state test",
          );
        }
      }
      for (
        const [receiver, sender, id, uid] of [[b, a, midA, uidB!], [
          a,
          b,
          midB,
          uidA!,
        ]] as const
      ) {
        await op(
          receiver.rpc("ack_messages", { cid: target, mark_read: false }),
        );
        const receipt = await value(
          sender.from("message_receipts").select("delivered_at").eq(
            "message_id",
            id,
          ).eq("user_id", uid).single(),
        );
        check(receipt.delivered_at);
        await op(
          receiver.rpc("ack_messages", { cid: target, mark_read: true }),
        );
      }
      await deadline(Promise.all([readA.promise, readB.promise]));
    });
    await step(
      required[7],
      () => media("test/fixtures/hosted-pixel.png", "image/png", "image"),
    );
    await step(
      required[8],
      () => media("test/fixtures/hosted-tone.ogg", "audio/ogg", "voice"),
    );
    await step(required[9], async () => {
      ready();
      const group: string = await value(
        a.rpc("create_group", {
          title: `Acceptance ${crypto.randomUUID().slice(0, 8)}`,
        }),
      );
      groups.push(group);
      await op(
        a.rpc("manage_group", { cid: group, action: "invite", target: uidB }),
      );
      const invite = await value(
        b.from("group_invitations").select("id").eq("conversation_id", group)
          .eq("invitee_id", uidB!).single(),
      );
      await value(b.rpc("accept_invitation", { iid: invite.id }));
      const id = crypto.randomUUID();
      await send(a, id, "Group acceptance message", group);
      check(
        (await value(b.from("messages").select("id").eq("id", id))).length ===
          1,
      );
      await send(b, crypto.randomUUID(), "Group reply", group);
    });
    await step(required[10], async () => {
      ready();
      const group: string = await value(
        a.rpc("create_group", { title: "Private authorization test" }),
      );
      groups.push(group);
      const id = crypto.randomUUID();
      await send(a, id, "Only A may read this fixture", group);
      for (const outsider of [b, anonymous]) {
        const { data, error, status } = await outsider.from("messages").select(
          "id",
        ).eq(
          "id",
          id,
        );
        check(
          error
            ? [401, 403].includes(status) && error.code === "42501"
            : data?.length === 0,
        );
        const write = await outsider.rpc("send_message", {
          cid: group,
          mid: crypto.randomUUID(),
          content: "Denied intrusion",
        });
        check(write.error && ["P0001", "42501"].includes(write.error.code));
      }
    });
    await step(required[11], async () => {
      const target = conversation();
      const existing = await op(
        b.from("user_blocks").select("blocker_id").eq("blocker_id", uidB!).eq(
          "blocked_id",
          uidA!,
        ).maybeSingle(),
      );
      if (existing) {
        throw new Blocked(
          "Test accounts already block each other; existing owner state was preserved",
        );
      }
      await op(
        b.from("user_blocks").insert({ blocker_id: uidB, blocked_id: uidA }),
      );
      insertedBlock = true;
      const blockedMessage = await a.rpc("send_message", {
        cid: target,
        mid: crypto.randomUUID(),
        content: "Must be blocked",
      });
      check(
        blockedMessage.error?.code === "P0001" &&
          blockedMessage.error.message === "Interaction blocked",
      );
      const blockedCall = await a.rpc("start_call", {
        cid: target,
        use_video: false,
      });
      check(
        blockedCall.error?.code === "P0001" &&
          blockedCall.error.message === "Unavailable",
      );
      const blockedDirect = await a.rpc("create_direct", { peer: uidB });
      check(
        blockedDirect.error?.code === "P0001" &&
          blockedDirect.error.message === "Unavailable",
      );
      await op(
        b.from("user_blocks").delete().eq("blocker_id", uidB!).eq(
          "blocked_id",
          uidA!,
        ),
      );
      insertedBlock = false;
    });
    await step("Status privacy and view tracking", async () => {
      ready();
      const settings = await value(
        a.from("user_settings").select("status_privacy").eq("user_id", uidA!)
          .single(),
      );
      if (settings.status_privacy !== "contacts") {
        throw new Blocked(
          "Test account A must explicitly enable contact-scoped status visibility",
        );
      }
      const existing = await op(
        a.from("contacts").select("contact_id").eq("owner_id", uidA!).eq(
          "contact_id",
          uidB!,
        ).maybeSingle(),
      );
      if (!existing) {
        await op(
          a.from("contacts").insert({ owner_id: uidA, contact_id: uidB }),
        );
        insertedContact = true;
      }
      const id: string = await value(
        a.rpc("create_status", { content: "Hosted status acceptance" }),
      );
      statuses.push(id);
      check(
        (await value(b.from("status_updates").select("id").eq("id", id)))
          .length === 1,
      );
      await op(b.rpc("view_status", { sid: id }));
      check(
        (await value(
          a.from("status_views").select("user_id").eq("status_id", id).eq(
            "user_id",
            uidB!,
          ),
        )).length === 1,
      );
    });
    if (config.TEST_CALL_SIGNALING === true) {
      await step("LiveKit token authorization and call signaling", async () => {
        const target = conversation();
        const call: string = await value(
          a.rpc("start_call", { cid: target, use_video: false }),
        );
        calls.push(call);
        check(accessDenied(
          (await b.functions.invoke("livekit-token", {
            body: { call_id: call },
          })).error,
        ));
        await op(
          b.rpc("transition_call", { callid: call, action: "accept" }),
        );
        for (const client of [a, b]) {
          const grant = await value(
            client.functions.invoke("livekit-token", {
              body: { call_id: call },
            }),
          );
          check(
            grant.url?.startsWith("wss://") && typeof grant.token === "string",
          );
          const payload = grant.token.split(".")[1].replaceAll("-", "+")
            .replaceAll("_", "/");
          const claims = JSON.parse(
            atob(payload.padEnd(Math.ceil(payload.length / 4) * 4, "=")),
          );
          check(
            claims.sub === (client === a ? uidA : uidB) &&
              claims.exp > claims.iat && claims.exp - claims.iat <= 300 &&
              claims.video?.roomJoin &&
              claims.video?.room,
          );
        }
        await op(a.rpc("transition_call", { callid: call, action: "end" }));
        check(
          (await value(
            b.from("call_history").select("outcome").eq("call_id", call)
              .single(),
          )).outcome === "ended",
        );
        check(accessDenied(
          (await a.functions.invoke("livekit-token", {
            body: { call_id: call },
          })).error,
        ));
      });
    } else {record(
        "LiveKit token authorization and call signaling",
        "BLOCKED",
        "Enable TEST_CALL_SIGNALING only after confirming server secrets and function deployment",
      );}
    for (const scenario of required.slice(12)) {
      record(
        scenario,
        "BLOCKED",
        "Requires the configured Android app on real authenticated devices; a database/token test cannot verify this scenario",
      );
    }
  } finally {
    await step("Cleanup of resources created by this test run", async () => {
      let cleanupFailed = false;
      const clean = async (action: () => PromiseLike<unknown>) => {
        try {
          await action();
        } catch {
          cleanupFailed = true;
        }
      };
      // Only run-owned IDs are touched. Retained direct conversation metadata,
      // account identities, jobs and soft-delete tombstones require owner cleanup.
      for (const { client, channel } of channels) {
        await clean(() => client.removeChannel(channel));
      }
      if (insertedBlock) {
        await clean(() =>
          op(
            b.from("user_blocks").delete().eq("blocker_id", uidB!).eq(
              "blocked_id",
              uidA!,
            ),
          )
        );
      }
      for (const call of calls) {
        await clean(() =>
          op(a.rpc("transition_call", { callid: call, action: "end" }))
        );
      }
      for (const { client, id } of messages) {
        await clean(() => op(client.rpc("delete_message", { mid: id })));
      }
      if (objects.length) {
        await clean(() => value(a.storage.from("chat-media").remove(objects)));
      }
      for (const id of statuses) {
        await clean(() => op(a.rpc("delete_status", { sid: id })));
      }
      for (const id of groups) {
        await clean(() =>
          op(a.rpc("manage_group", { cid: id, action: "delete" }))
        );
      }
      if (insertedContact) {
        await clean(() =>
          op(
            a.from("contacts").delete().eq("owner_id", uidA!).eq(
              "contact_id",
              uidB!,
            ),
          )
        );
      }
      if (cleanupFailed) {
        throw new Error("Some staging resources require owner cleanup");
      }
    });
    for (const client of [a, b, anonymous]) {
      await client.removeAllChannels();
      await client.auth.signOut({ scope: "local" });
    }
  }
}

if (import.meta.main) {
  let config: Config = {};
  try {
    config = JSON.parse(await Deno.readTextFile("config/hosted-test.json"));
  } catch { /* Missing config is reported as BLOCKED. */ }
  try {
    await run(config);
  } catch {
    record(
      "Hosted runner",
      "FAIL",
      "Unexpected execution failure; private details were suppressed",
    );
  }
  const output = {
    generated_at: new Date().toISOString(),
    provider_evidence_only: true,
    results,
  };
  await Deno.writeTextFile(
    "docs/hosted-results.json",
    JSON.stringify(output, null, 2) + "\n",
  );
  const failed = results.some((r) => r.status === "FAIL");
  const blocked = results.some((r) => r.status === "BLOCKED");
  Deno.exit(failed ? 1 : blocked ? 2 : 0);
}
