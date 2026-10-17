import { pushPayload } from "./push_payload.ts";
Deno.test("message, group and missed-call payloads never include private previews", () => {
  for (const kind of ["message", "call", "missed_call"]) {
    const job = {
      kind,
      resource_id: "12345678-1234-1234-1234-123456789abc",
      sender: "Private sender",
      body: "Private text",
      image: "https://private.invalid/picture",
    };
    const payload = pushPayload(job, "unit-test-device-target");
    const serialized = JSON.stringify(payload);
    if (
      serialized.includes("Private") || serialized.includes("private.invalid")
    ) {
      throw new Error("Private preview escaped into provider payload");
    }
    if (
      (kind !== "call" &&
        (payload.message.notification?.title !== "Calculator" ||
          payload.message.notification?.body !== (kind === "message" ? "New update arrived" : "New activity"))) ||
      (kind === "call" && payload.message.notification !== undefined) ||
      (kind !== "call" &&
        payload.message.android.notification?.visibility !== "PRIVATE") ||
      Object.keys(payload.message.data).sort().join() !==
        (kind === "call" ? "expires_at,kind,resource_id" : "kind,resource_id")
    ) {
      throw new Error("Notification privacy policy violated");
    }
  }
});

Deno.test("message notifications bind recipient and use a stable generic Android tag/icon", () => {
  const job = { kind: "message", resource_id: "message-id", recipient_id: "recipient-id", body: "Private text", version: "999" };
  const first = pushPayload(job, "token");
  const retry = pushPayload(job, "token");
  if (first.message.android.notification?.tag !== "message:message-id" ||
      first.message.android.notification?.icon !== "ic_notification" ||
      first.message.data.recipient_id !== "recipient-id" ||
      JSON.stringify(first) !== JSON.stringify(retry) ||
      first.message.notification?.body !== "New update arrived" ||
      JSON.stringify(first).includes("latest version")) throw new Error("Message disguise/dedup violated");
});

Deno.test("message TTL cannot outlive disappearance or malformed expiry", () => {
  for (const expires_at of ["not-a-date", "2000-01-01T00:00:00Z"]) {
    if (pushPayload({ kind: "message", resource_id: "id", expires_at }, "token").message.android.ttl !== "0s") {
      throw new Error("Expired payload retained");
    }
  }
  const ttl = pushPayload({ kind: "message", resource_id: "id", expires_at: new Date(Date.now() + 30000).toISOString() }, "token").message.android.ttl;
  if (Number(ttl.slice(0, -1)) > 30) throw new Error("TTL exceeds message lifetime");
});

Deno.test("background/terminated messages use one generic OS notification with opaque routing only", () => {
  const payload = pushPayload({ kind: "message", resource_id: "id", recipient_id: "owner" }, "token").message;
  if (!payload.notification || payload.notification.title !== "Calculator" || payload.notification.body !== "New update arrived" ||
      payload.android.notification?.tag !== "message:id" ||
      Object.keys(payload.data).sort().join() !== "kind,recipient_id,resource_id") throw new Error("Background message policy changed");
});
Deno.test("incoming calls use the dedicated channel and short TTL", () => {
  const payload = pushPayload({ kind: "call", resource_id: "call-id" }, "test");
  if (
    payload.message.android.ttl !== "45s" ||
    payload.message.android.priority !== "HIGH" ||
    payload.message.android.notification !== undefined
  ) {
    throw new Error("Incoming call delivery policy violated");
  }
});
