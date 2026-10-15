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
      payload.message.notification.title !== "Calculator" ||
      payload.message.notification.body !== "New activity" ||
      payload.message.android.notification.visibility !== "PRIVATE" ||
      Object.keys(payload.message.data).sort().join() !== "kind,resource_id"
    ) {
      throw new Error("Notification privacy policy violated");
    }
  }
});
Deno.test("incoming calls use the dedicated channel and short TTL", () => {
  const payload = pushPayload({ kind: "call", resource_id: "call-id" }, "test");
  if (
    payload.message.android.ttl !== "45s" ||
    payload.message.android.priority !== "HIGH" ||
    payload.message.android.notification.channel_id !== "incoming_calls"
  ) {
    throw new Error("Incoming call delivery policy violated");
  }
});
