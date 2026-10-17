import {
  authenticated,
  body,
  HttpError,
  json,
  serve,
} from "../_shared/http.ts";
import { mediaMatches } from "../_shared/media.ts";
serve(async (req) => {
  const { user, client, admin } = await authenticated(req);
  const input = await body(req);
  const bucket = String(input.bucket), path = String(input.path);
  if (
    !["chat-media", "status-media", "avatars"].includes(bucket) ||
    path.length > 400 || path.includes("..")
  ) throw new HttpError(400, "Invalid object");
  const segments = path.split("/");
  if ((bucket === "chat-media" ? segments[1] : segments[0]) !== user.id) {
    throw new HttpError(403, "Object owner mismatch");
  }
  // Download with the user's token: storage RLS verifies conversation membership.
  const { data: blob, error } = await client.storage.from(bucket).download(
    path,
  );
  if (error || !blob) throw new HttpError(403, "Object unavailable");
  const bytes = new Uint8Array(await blob.arrayBuffer());
  const mime = blob.type.split(";")[0];
  if (
    !mediaMatches(bytes, mime) ||
    (bucket === "avatars" &&
      (!mime.startsWith("image/") || bytes.length > 5 * 1024 * 1024)) ||
    (bucket === "status-media" &&
      !["image/jpeg", "image/png", "image/webp", "video/mp4"].includes(mime))
  ) {
    await admin.storage.from(bucket).remove([path]);
    throw new HttpError(400, "File type validation failed");
  }
  let mediaExpiresAt: string | null = null;
  if (
    bucket === "chat-media" && segments[2] !== "icons" &&
    (mime.startsWith("image/") || mime.startsWith("video/"))
  ) {
    const digest = Array.from(
      new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)),
    )
      .map((value) => value.toString(16).padStart(2, "0")).join("");
    const { data, error } = await admin.rpc("record_chat_upload", {
      object_path: path,
      content_digest: digest,
    });
    if (error || typeof data !== "string") {
      throw new HttpError(403, "Media unavailable");
    }
    mediaExpiresAt = data;
    if (Date.parse(data) <= Date.now()) {
      throw new HttpError(410, "Media expired");
    }
  }
  const { error: saveError } = await admin.from("media_validations").upsert({
    bucket,
    object_path: path,
    user_id: user.id,
    mime_type: mime,
    size_bytes: bytes.length,
  });
  if (saveError) throw new Error("Validation could not be recorded");
  return json({ valid: true, media_expires_at: mediaExpiresAt });
});
