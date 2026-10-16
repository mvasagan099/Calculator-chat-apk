import {
  authenticated,
  body,
  HttpError,
  json,
  serve,
  uuid,
} from "../_shared/http.ts";
import { closeRoom, removeParticipant } from "../_shared/livekit.ts";
serve(async (req) => {
  const { client, admin } = await authenticated(req);
  const input = await body(req);
  const id = uuid(input.call_id);
  const action = String(input.action);
  let result;
  if (action === "invite" || action === "remove") {
    result = await client.rpc(
      action === "invite"
        ? "invite_call_participant"
        : "remove_call_participant",
      { callid: id, person: uuid(input.person) },
    );
  } else {
    if (
      ![
        "accept",
        "join",
        "reject",
        "busy",
        "cancel",
        "timeout",
        "end",
        "leave",
        "disconnect",
        "end_for_all",
      ].includes(action)
    ) throw new HttpError(400, "Invalid action");
    result = await client.rpc("transition_call", { callid: id, action });
  }
  if (result.error) throw new HttpError(403, "Call action unavailable");
  // Database authorization/state commits first. Provider failure leaves durable
  // cleanup work for maintenance rather than rolling back a successful action.
  let cleanupPending = false;
  try {
    const { data: call, error } = await admin.from("calls").select(
      "state,room_name",
    ).eq("id", id).single();
    if (error || !call) throw new Error("Call unavailable");
    if (!["ringing", "accepted"].includes(call.state)) {
      await closeRoom(call.room_name);
      await admin.from("calls").update({
        media_closed_at: new Date().toISOString(),
      }).eq("id", id);
    } else {
      const { data: jobs, error: jobsError } = await admin.rpc(
        "call_evictions",
      );
      if (jobsError) throw jobsError;
      for (const item of jobs ?? []) {
        if (item.call_id === id) {
          await removeParticipant(item.room_name, item.identity);
          const { error } = await admin.rpc("complete_call_eviction", {
            callid: id,
            participant_identity: item.identity,
          });
          if (error) throw error;
        }
      }
    }
  } catch {
    cleanupPending = true;
  }
  return json({ updated: true, cleanupPending });
});
