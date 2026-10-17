import { cleanupChatMedia } from "../_shared/media_cleanup.ts";
import { closeRoom, removeParticipant } from "../_shared/livekit.ts";
import {
  adminClient,
  HttpError,
  json,
  serve,
  workerAuthorized,
} from "../_shared/http.ts";
import { dispatchPush } from "../_shared/push.ts";
serve(async (req) => {
  if (!workerAuthorized(req)) throw new HttpError(401, "Unauthorized");
  const admin = adminClient();
  const { error: expiryError } = await admin.rpc("expire_messages");
  if (expiryError) throw expiryError;
  const mediaCleanup = await cleanupChatMedia(admin);
  const { error: reconcileError } = await admin.rpc("reconcile_calls");
  if (reconcileError) throw reconcileError;
  const { data: evictions, error: evictionError } = await admin.rpc(
    "call_evictions",
  );
  if (evictionError) throw evictionError;
  let participantCleanupErrors = 0;
  for (const item of evictions ?? []) {
    try {
      await removeParticipant(item.room_name, item.identity);
      const { error } = await admin.rpc("complete_call_eviction", {
        callid: item.call_id,
        participant_identity: item.identity,
      });
      if (error) throw error;
    } catch {
      participantCleanupErrors++;
    }
  }
  const { error: maintenanceError } = await admin.rpc("maintenance");
  if (maintenanceError) throw maintenanceError;
  const { data: endedCalls } = await admin.from("calls").select("id,room_name")
    .not("state", "in", "(ringing,accepted)").is("media_closed_at", null).limit(
      50,
    );
  let roomCleanupErrors = 0;
  for (const call of endedCalls ?? []) {
    try {
      await closeRoom(call.room_name);
      await admin.from("calls").update({
        media_closed_at: new Date().toISOString(),
      }).eq("id", call.id);
    } catch {
      roomCleanupErrors++;
    }
  }
  const { data: objects, error } = await admin.rpc("storage_gc_candidates");
  if (error) throw error;
  for (const bucket of ["chat-media", "status-media", "avatars"]) {
    const paths = (objects ?? []).filter((o: { bucket: string }) =>
      o.bucket === bucket
    ).map((o: { path: string }) => o.path);
    if (paths.length) {
      const { error: removeError } = await admin.storage.from(bucket).remove(
        paths,
      );
      if (removeError) throw removeError;
      await admin.from("media_validations").delete().eq("bucket", bucket).in(
        "object_path",
        paths,
      );
    }
  }
  await admin.from("status_updates").delete().lt(
    "expires_at",
    new Date().toISOString(),
  );
  return json({
    cleanup: true,
    ...mediaCleanup,
    roomCleanupErrors,
    participantCleanupErrors,
    ...await dispatchPush(),
  });
});
