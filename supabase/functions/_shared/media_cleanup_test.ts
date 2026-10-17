import { cleanupChatMedia } from "./media_cleanup.ts";
import type { adminClient } from "./http.ts";
function check(condition: unknown) {
  if (!condition) throw new Error("Cleanup contract failed");
}
function fixture(
  options: { removeFails?: boolean; ackFails?: boolean; count?: number } = {},
) {
  const calls: string[] = [];
  let removed: string[] = [];
  const admin = {
    rpc(name: string) {
      calls.push(name);
      return Promise.resolve({
        data: name === "retention_media_jobs"
          ? Array.from(
            { length: options.count ?? 2 },
            (_, n) => ({ bucket: "chat-media", path: `private-${n}` }),
          )
          : 2,
        error: name === "complete_media_cleanup" && options.ackFails
          ? new Error("ack failed")
          : null,
      });
    },
    storage: {
      from(bucket: string) {
        check(bucket === "chat-media");
        return {
          remove(paths: string[]) {
            calls.push("remove");
            removed = paths;
            return Promise.resolve({
              error: options.removeFails ? new Error("storage failed") : null,
            });
          },
        };
      },
    },
  } as unknown as ReturnType<typeof adminClient>;
  return {
    admin,
    calls,
    get removed() {
      return removed;
    },
  };
}
Deno.test("retention deletes bytes before acknowledging metadata", async () => {
  const f = fixture();
  const result = await cleanupChatMedia(f.admin);
  check(
    f.calls.join() ===
      "queue_expired_chat_media,retention_media_jobs,remove,complete_media_cleanup,media_retention_health",
  );
  check(result.mediaDeleted === 2);
});
Deno.test("Storage failure retains cleanup jobs for retry", async () => {
  const f = fixture({ removeFails: true });
  try {
    await cleanupChatMedia(f.admin);
    throw new Error("must fail");
  } catch {
    check(!f.calls.includes("complete_media_cleanup"));
  }
});
Deno.test("failed acknowledgement can retry an idempotent removal", async () => {
  const f = fixture({ ackFails: true });
  let failed = false;
  try {
    await cleanupChatMedia(f.admin);
  } catch {
    failed = true;
  }
  check(failed && f.calls.includes("remove"));
  const retry = fixture();
  await cleanupChatMedia(retry.admin);
  check(retry.calls.includes("complete_media_cleanup"));
});
Deno.test("cleanup work remains bounded to 500 paths", async () => {
  const f = fixture({ count: 700 });
  await cleanupChatMedia(f.admin);
  check(f.removed.length === 500);
});
