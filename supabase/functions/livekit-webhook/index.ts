import { WebhookReceiver } from "livekit-server-sdk";
import {
  adminClient,
  HttpError,
  json,
  required,
  serve,
} from "../_shared/http.ts";
serve(async (req) => {
  const receiver = new WebhookReceiver(
    required("LIVEKIT_API_KEY"),
    required("LIVEKIT_API_SECRET"),
  );
  let event;
  try {
    event = await receiver.receive(
      await req.text(),
      req.headers.get("authorization") ?? undefined,
    );
  } catch {
    throw new HttpError(401, "Invalid webhook");
  }
  if (event.event === "room_finished" && event.room?.name) {
    const admin = adminClient();
    const { data: call } = await admin.from("calls").select("id,state").eq(
      "room_name",
      event.room.name,
    ).maybeSingle();
    if (call && ["accepted", "ringing"].includes(call.state)) {
      const state = call.state === "ringing" ? "missed" : "disconnected";
      const { data: updated } = await admin.from("calls").update({
        state,
        ended_at: new Date().toISOString(),
      }).eq("id", call.id).in("state", ["ringing", "accepted"]).select("id");
      if (updated?.length) {
        const { data: participants } = await admin.from("call_participants")
          .select("user_id").eq("call_id", call.id);
        await admin.from("call_history").upsert(
          (participants ?? []).map((p) => ({
            call_id: call.id,
            user_id: p.user_id,
            outcome: state,
          })),
          { onConflict: "call_id,user_id", ignoreDuplicates: true },
        );
      }
    }
  }
  return json({ received: true });
});
