-- Add an owner-verification predicate for service-role media validation.
-- Supabase Storage .list() omits owner fields. No RLS or bucket permissions change.
-- SECURITY DEFINER does not expose any owner metadata; returns a single boolean.
create or replace function public.media_upload_owned(
  bucket_name text, object_path text, uploader_id uuid
) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select bucket_name = any(array['chat-media','status-media','avatars'])
     and exists (
       select 1 from storage.objects o
        where o.bucket_id = bucket_name
          and o.name = object_path
          and o.owner_id = uploader_id::text
     );
$$;
revoke all on function public.media_upload_owned(text,text,uuid) from public, anon, authenticated;
grant execute on function public.media_upload_owned(text,text,uuid) to service_role;
