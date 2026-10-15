import { closeRoom } from "../_shared/livekit.ts";
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
  const { data: retention, error: retentionError } = await admin.rpc(
    "retention_media_jobs",
  );
  if (retentionError) throw retentionError;
  const retentionPaths = (retention ?? []).map((item: { path: string }) =>
    item.path
  );
  if (retentionPaths.length) {
    const { error: deleteError } = await admin.storage.from("chat-media")
      .remove(retentionPaths);
    if (deleteError) throw deleteError;
    const { error: acknowledgeError } = await admin.rpc(
      "complete_media_cleanup",
      { paths: retentionPaths },
    );
    if (acknowledgeError) throw acknowledgeError;
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
  return json({ cleanup: true, roomCleanupErrors, ...await dispatchPush() });
});
