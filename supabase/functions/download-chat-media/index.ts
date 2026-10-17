import { authenticated, body, HttpError, serve } from "../_shared/http.ts";

// Storage's authenticated GET performs an object.info query which is rejected
// by the restrictive visual-read policy. Keep Storage private and RLS intact.
// This endpoint checks the JWT, device, membership, visual deadline and
// non-view-once message BEFORE privileged bytes can be read.
// The linked chat_media_deadline RPC performs message and membership checks.
export const downloadDependencies = { authenticated, body };
export async function handleDownloadChatMedia(
  req: Request, deps = downloadDependencies,
): Promise<Response> {
  const { client, admin } = await deps.authenticated(req);
  const input = await deps.body(req);
  const path = input.path;
  if (typeof path !== "string" || path.length > 400 ||
      path.split("/").length < 3 ||
      path.split("/").some((segment) =>
        !segment || segment === "." || segment === "..")) {
    throw new HttpError(400, "Invalid media path");
  }
  const { data: deadline, error: deadlineError } = await client.rpc(
    "chat_media_deadline", { path },
  );
  const expiry = deadline?.expires_at &&
    Date.parse(String(deadline.expires_at));
  if (deadlineError || typeof expiry !== "number" ||
      !Number.isFinite(expiry) || expiry <= Date.now()) {
    throw new HttpError(403, "Media unavailable");
  }
  const { data: blob, error: storageError } = await admin.storage.from(
    "chat-media",
  ).download(path);
  if (storageError || !blob) throw new HttpError(404, "Media unavailable");
  const mime = blob.type.split(";")[0].toLowerCase();
  if ((!mime.startsWith("image/") && !mime.startsWith("video/")) ||
      blob.size < 1 || blob.size > 25 * 1024 * 1024 ||
      expiry <= Date.now()) {
    throw new HttpError(403, "Media unavailable");
  }
  return new Response(blob.stream(), {
    status: 200,
    headers: {
      "Content-Type": mime,
      "Content-Length": String(blob.size),
      "Cache-Control": "private, no-store, max-age=0",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
if (import.meta.main) serve(handleDownloadChatMedia);
