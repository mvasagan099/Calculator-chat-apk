import {
  authenticated,
  body,
  HttpError,
  serve,
  uuid,
} from "../_shared/http.ts";
serve(async (req) => {
  const { user, client, admin } = await authenticated(req);
  const mid = uuid((await body(req)).message_id);
  // An authenticated caller must be able to see the unexpired message under
  // its own RLS before the service-only atomic claim. No URL is disclosed.
  const { data: visible, error: visibleError } = await client.from("messages")
    .select("id").eq("id", mid).maybeSingle();
  if (visibleError || !visible) throw new HttpError(403, "Media unavailable");
  const { data: claim, error } = await admin.rpc("claim_view_once", {
    mid,
    viewer: user.id,
  });
  if (error || !claim) throw new HttpError(403, "Media unavailable");
  // Claim commits before bytes are fetched. A failed/interrupted opening is
  // consumed too; retry must never release the same content a second time.
  const { data: blob, error: downloadError } = await admin.storage
    .from("chat-media").download(claim.object_path);
  if (
    downloadError || !blob ||
    Date.parse(claim.media_expires_at) <= Date.now() ||
    blob.size !== claim.size_bytes ||
    blob.size > 26214400
  ) {
    throw new HttpError(410, "Media no longer available");
  }
  return new Response(blob, {
    headers: {
      "Content-Type": "application/octet-stream",
      "X-Media-Type": claim.mime_type,
      "Cache-Control": "no-store, private, max-age=0",
      "X-Content-Type-Options": "nosniff",
    },
  });
});
