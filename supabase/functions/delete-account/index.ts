import { closeRoom } from "../_shared/livekit.ts";
import {
  authenticated,
  body,
  HttpError,
  json,
  serve,
} from "../_shared/http.ts";
serve(async (req) => {
  const { user, client, admin } = await authenticated(req);
  const input = await body(req);
  if (typeof input.password !== "string" || !user.email) {
    throw new HttpError(400, "Password reauthentication required");
  }
  const { data, error } = await client.auth.signInWithPassword({
    email: user.email,
    password: input.password,
  });
  if (error || data.user?.id !== user.id) {
    throw new HttpError(403, "Reauthentication failed");
  }
  const { data: participants, error: participantError } = await admin.from(
    "call_participants",
  ).select("call_id").eq("user_id", user.id);
  if (participantError) throw participantError;
  const ids = (participants ?? []).map((p) => p.call_id);
  for (let offset = 0; offset < ids.length; offset += 100) {
    const { data: calls, error: callError } = await admin.from("calls").select(
      "id,room_name",
    ).in("id", ids.slice(offset, offset + 100)).is("media_closed_at", null);
    if (callError) throw callError;
    for (const call of calls ?? []) {
      await closeRoom(call.room_name);
      await admin.from("calls").update({
        state: "ended",
        ended_at: new Date().toISOString(),
        media_closed_at: new Date().toISOString(),
      }).eq("id", call.id);
    }
  }
  // Storage API deletion is required: never DELETE storage.objects directly.
  for (let batch = 0; batch < 100; batch++) {
    const { data: objects, error: gcError } = await admin.rpc(
      "storage_gc_candidates",
      { owner_filter: user.id },
    );
    if (gcError) throw gcError;
    if (!objects?.length) break;
    for (const bucket of ["chat-media", "status-media", "avatars"]) {
      const paths = objects.filter((o: { bucket: string }) =>
        o.bucket === bucket
      ).map((o: { path: string }) => o.path);
      if (paths.length) {
        const { error: removeError } = await admin.storage.from(bucket).remove(
          paths,
        );
        if (removeError) throw removeError;
      }
    }
    if (batch === 99) {
      throw new HttpError(409, "Cleanup is continuing; retry deletion");
    }
  }
  const { error: purgeError } = await admin.rpc("purge_account", {
    target: user.id,
  });
  if (purgeError) throw purgeError;
  const { error: deleteError } = await admin.auth.admin.deleteUser(user.id);
  if (deleteError) throw deleteError;
  return json({ deleted: true });
});
