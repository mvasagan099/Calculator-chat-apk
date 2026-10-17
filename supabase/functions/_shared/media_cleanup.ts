import type { adminClient } from "./http.ts";

export async function cleanupChatMedia(admin: ReturnType<typeof adminClient>) {
  const { data: queued, error: queueError } = await admin.rpc(
    "queue_expired_chat_media",
  );
  if (queueError) throw queueError;
  const { data, error } = await admin.rpc("retention_media_jobs");
  if (error) throw error;
  const paths: string[] = [
    ...new Set<string>(
      (data ?? []).slice(0, 500)
        .filter((item: { bucket: string }) => item.bucket === "chat-media")
        .map((item: { path: string }) => item.path),
    ),
  ];
  if (paths.length) {
    const { error: removeError } = await admin.storage.from("chat-media")
      .remove(paths);
    if (removeError) throw removeError; // Durable jobs survive failed deletion.
    const { error: ackError } = await admin.rpc("complete_media_cleanup", {
      paths,
    });
    if (ackError) throw ackError; // Re-removing absent objects is safe on retry.
  }
  const { data: health, error: healthError } = await admin.rpc(
    "media_retention_health",
  );
  if (healthError) throw healthError;
  return {
    retentionHealth: health,
    visualQueued: queued,
    mediaDeleted: paths.length,
  };
}
