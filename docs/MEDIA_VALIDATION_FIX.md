# Media uploads: ownership-safe validation

Uploads for chat images, videos, voice, audio and supported documents use private `chat-media` (25 MiB). Status media uses `status-media` (25 MiB); profile images use `avatars` (5 MiB).

**Verified failure:** Existing live `validate-media` v9 reads newly uploaded media through the uploader's SELECT RLS. The uploaded object is not yet linked to a message; the visual-media viewing policy rejects the read. Function logs show 403 after upload.

**Fix:** Migration `202610180015_media_upload_owner.sql` adds `public.media_upload_owned`, callable **only** by `service_role`, returning a boolean after matching the exact bucket, object path, and `storage.objects.owner_id` with the authenticated user. The updated Edge Function verifies user/device, exact Storage ownership, and current conversation membership before downloading with admin credentials solely to check content signatures. It still enforces existing size/MIME/expiry rules and doesn't expose storage bytes or admin credentials. Current Supabase Storage `.list()` no longer includes an `owner` field; the previous pending validator patch using `.list()` must **not** be deployed unchanged. <https://supabase.com/docs/reference/javascript/file-buckets-list>

**Deployment order:** Run migrations only after review. Verify `public.media_upload_owned` is restricted to service-role execution. Then deploy the updated `validate-media` Edge Function with its `_shared` imports and existing JWT settings. Never publish buckets, disable RLS, or loosen attachment permissions. New client APK with online-only audio/voice/file support is also needed for the SQLite fallback.

**Device testing:** New image, video, voice clip, MP3/M4A, PDF/TXT/ZIP/VCF in an approved chat. Ensure a failed validation does not insert a message. Then test readback, expiration, sender/recipient permissions, device revocation and size/MIME denial. Pending orphan media is **not** automatically committed or deleted. Do not delete encrypted local cache or change app signing key.
