begin;
-- Forward only. Applying this enables the policy for existing bytes too; approval
-- and the read-only impact preflight are required before deployment.
alter table public.message_attachments add column media_expires_at timestamptz;
-- Minimal keyed provenance survives deletion. No filename, message or bytes.
-- Identical bytes cannot gain a later lifetime through a retry/forward/reupload.
create table private.media_fingerprints(digest text primary key check(digest ~ '^[0-9a-f]{64}$'), deadline timestamptz not null);
create table private.chat_upload_deadlines(path text primary key, digest text references private.media_fingerprints, uploaded_at timestamptz not null, deadline timestamptz not null);
create index chat_upload_deadline_due on private.chat_upload_deadlines(deadline);
create index attachment_media_deadline on public.message_attachments(media_expires_at) where media_expires_at is not null;
alter table private.media_fingerprints enable row level security;
alter table private.chat_upload_deadlines enable row level security;
revoke all on private.media_fingerprints,private.chat_upload_deadlines from public,anon,authenticated;
-- Backfill uses Storage timestamps, never attachment/client timestamps. Unknown
-- origins fail closed. Persistent group icons are exempt from object deletion.
insert into private.chat_upload_deadlines(path,uploaded_at,deadline)
select name,created_at,created_at+interval '48 hours' from storage.objects where bucket_id='chat-media' and (metadata->>'mimetype' like 'image/%' or metadata->>'mimetype' like 'video/%');
update public.message_attachments a set media_expires_at=coalesce((select deadline from private.chat_upload_deadlines d where d.path=a.object_path),'-infinity'::timestamptz)
where a.mime_type like 'image/%' or a.mime_type like 'video/%';

create function public.record_chat_upload(object_path text,content_digest text) returns timestamptz
language plpgsql security definer set search_path='' as $$
declare uploaded timestamptz; deadline_value timestamptz;begin
 if content_digest !~ '^[0-9a-f]{64}$' then raise exception 'Invalid digest';end if;
 select o.created_at into uploaded from storage.objects o where o.bucket_id='chat-media' and o.name=object_path;
 if uploaded is null then raise exception 'Object unavailable';end if;
 insert into private.media_fingerprints(digest,deadline) values(content_digest,uploaded+interval '48 hours')
 on conflict(digest) do update set deadline=least(private.media_fingerprints.deadline,excluded.deadline)
 returning deadline into deadline_value;
 insert into private.chat_upload_deadlines(path,digest,uploaded_at,deadline) values(object_path,content_digest,uploaded,deadline_value)
 on conflict(path) do update set digest=excluded.digest,deadline=least(private.chat_upload_deadlines.deadline,excluded.deadline)
 returning deadline into deadline_value;
 -- Retroactively shorten identical earlier registrations if their origin was
 -- discovered out of order; deadlines only decrease.
 update private.chat_upload_deadlines set deadline=least(deadline,deadline_value) where digest=content_digest;
 update public.message_attachments a set media_expires_at=least(a.media_expires_at,deadline_value)
 where a.object_path in(select path from private.chat_upload_deadlines where digest=content_digest) and a.media_expires_at is not null;
 return deadline_value;
end $$;
revoke all on function public.record_chat_upload(text,text) from public,anon,authenticated;
grant execute on function public.record_chat_upload(text,text) to service_role;

create function private.attachment_deadline() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if split_part(new.object_path,'/',3)='icons' or exists(select 1 from public.groups where avatar_path=new.object_path) then raise exception 'Group icons cannot be chat attachments';end if;
 if new.mime_type like 'image/%' or new.mime_type like 'video/%' then
  select deadline into new.media_expires_at from private.chat_upload_deadlines where path=new.object_path;
  if new.media_expires_at is null or new.media_expires_at<=clock_timestamp() then raise exception 'Media expired or unvalidated';end if;
 else new.media_expires_at=null;end if;
 return new;
end $$;
create trigger attachment_deadline before insert on public.message_attachments for each row execute function private.attachment_deadline();
-- New group icons use a reserved namespace that cannot be attached as chat
-- media. This prevents promoting expiring attachments into persistent icons.
create function private.persistent_group_icon() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.avatar_path is distinct from old.avatar_path and new.avatar_path is not null and
 (split_part(new.avatar_path,'/',3)<>'icons' or exists(select 1 from public.message_attachments where object_path=new.avatar_path))
 then raise exception 'Use a dedicated group icon upload';end if;
 return new;
end $$;
create trigger persistent_group_icon before update of avatar_path on public.groups for each row execute function private.persistent_group_icon();
revoke all on function private.persistent_group_icon() from public,anon,authenticated;
-- Normal RLS remains in force. This restrictive policy also covers orphan
-- drafts, and prevents clients minting unbounded signed URLs for visual media.
-- Authenticated downloads re-evaluate RLS at each request. Storage signed URLs
-- issued before deployment require a cutover drain; see deployment document.
create function private.chat_visual_access(path text,mime text,uploaded timestamptz) returns boolean
language sql stable security definer set search_path='' as $$
 select case when exists(select 1 from public.groups where avatar_path=path)
 then true
 when mime like 'image/%' or mime like 'video/%' then
   least(uploaded+interval '48 hours',coalesce((select deadline from private.chat_upload_deadlines where path=$1),uploaded+interval '48 hours'))>now()
   and storage.allow_only_operation('object.get_authenticated')
 else true end
$$;
revoke all on function private.chat_visual_access(text,text,timestamptz) from public,anon;
grant execute on function private.chat_visual_access(text,text,timestamptz) to authenticated;
create policy chat_visual_lifetime on storage.objects as restrictive for select to authenticated
using(bucket_id<>'chat-media' or private.chat_visual_access(name,metadata->>'mimetype',created_at));

create policy attachment_visual_lifetime on public.message_attachments as restrictive for select to authenticated
using(media_expires_at is null or media_expires_at>now());

create or replace function public.retention_media_jobs() returns table(bucket text,path text) language sql stable security definer set search_path='' as $$
 select j.bucket,j.path from private.media_cleanup_jobs j where j.not_before<=now()
 and not exists(select 1 from public.groups g where g.avatar_path=j.path)
 order by j.created_at limit 500
$$;

create function public.chat_media_deadline(path text) returns jsonb language plpgsql security definer set search_path='' as $$
declare deadline_value timestamptz;begin
 perform private.require_session();
 if not private.chat_object_readable(path) then raise exception 'Media unavailable';end if;
 select least(d.deadline,coalesce(m.expires_at,d.deadline)) into deadline_value
 from private.chat_upload_deadlines d join public.message_attachments a on a.object_path=d.path
 join public.messages m on m.id=a.message_id
 where d.path=$1 and not m.view_once and m.deleted_at is null and a.media_expires_at is not null
 order by d.deadline limit 1;
 if deadline_value is null or deadline_value<=clock_timestamp() then raise exception 'Media expired';end if;
 return jsonb_build_object('expires_at',deadline_value,'server_time',clock_timestamp());
end $$;
revoke all on function public.chat_media_deadline(text) from public,anon;
grant execute on function public.chat_media_deadline(text) to authenticated;

create function public.queue_expired_chat_media() returns integer language plpgsql security definer set search_path='' as $$
declare count_queued integer;begin
 insert into private.media_cleanup_jobs(bucket,path)
 select 'chat-media',candidate.path from (
  select d.path,d.uploaded_at from private.chat_upload_deadlines d where d.deadline<=now()
  union all
  select a.object_path,a.created_at from public.message_attachments a where a.media_expires_at<=now()
  union all
  select o.name,o.created_at from storage.objects o where o.bucket_id='chat-media'
   and (o.metadata->>'mimetype' like 'image/%' or o.metadata->>'mimetype' like 'video/%')
   and o.created_at<=now()-interval '48 hours'
 ) candidate
 where not exists(select 1 from public.groups g where g.avatar_path=candidate.path)
 group by candidate.path order by min(candidate.uploaded_at) limit 500 on conflict do nothing;
 get diagnostics count_queued=row_count;
 return count_queued;
end $$;
create or replace function public.complete_media_cleanup(paths text[]) returns void language plpgsql security definer set search_path='' as $$
begin
 -- Only acknowledge queued, due paths after the authenticated worker removed
 -- Storage bytes. Retried deletes are safe; no job is lost on Storage failure.
 delete from public.message_attachments a where a.object_path=any(paths)
 and exists(select 1 from private.media_cleanup_jobs j where j.path=a.object_path and j.not_before<=now())
 and (a.media_expires_at<=now() or exists(select 1 from public.messages m where m.id=a.message_id and m.view_once and m.view_once_opened_at is not null));
 delete from public.media_validations where bucket='chat-media' and object_path=any(paths)
 and exists(select 1 from private.media_cleanup_jobs j where j.path=object_path and j.not_before<=now());
 delete from private.chat_upload_deadlines where path=any(paths) and exists(select 1 from private.media_cleanup_jobs j where j.path=private.chat_upload_deadlines.path and j.not_before<=now());
 delete from private.media_cleanup_jobs where bucket='chat-media' and path=any(paths) and not_before<=now();
end $$;
create function public.media_retention_health() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('due_jobs',count(*) filter(where not_before<=now()),
 'oldest_due',min(not_before) filter(where not_before<=now())) from private.media_cleanup_jobs
$$;
revoke all on function public.media_retention_health() from public,anon,authenticated;
grant execute on function public.media_retention_health() to service_role;
revoke all on function public.queue_expired_chat_media() from public,anon,authenticated;
grant execute on function public.queue_expired_chat_media() to service_role;
-- Keep the 24-hour view-once policy AND the upload deadline. The guarded
-- service claim still serializes consumption and checks recipient ownership.
alter function public.claim_view_once(uuid,uuid) rename to claim_view_once_before_upload_deadline;
alter function public.claim_view_once_before_upload_deadline(uuid,uuid) set schema private;
create function public.claim_view_once(mid uuid,viewer uuid) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.message_attachments a where a.message_id=mid and a.media_expires_at>clock_timestamp()) then raise exception 'Media expired';end if;
 return private.claim_view_once_before_upload_deadline(mid,viewer) || jsonb_build_object('media_expires_at',
  (select least(a.media_expires_at,m.expires_at) from public.message_attachments a join public.messages m on m.id=a.message_id where a.message_id=mid limit 1));
end $$;
revoke all on function public.claim_view_once(uuid,uuid) from public,anon,authenticated;
grant execute on function public.claim_view_once(uuid,uuid) to service_role;
revoke all on function private.claim_view_once_before_upload_deadline(uuid,uuid) from public,anon,authenticated,service_role;
create function private.cap_view_once_deadline() returns trigger language plpgsql security definer set search_path='' as $$
declare deadline_value timestamptz;begin
 if new.view_once then
  select min(media_expires_at) into deadline_value from public.message_attachments where message_id=new.id;
  if deadline_value is not null then
   new.expires_at=least(new.expires_at,deadline_value);
   new.expiration_seconds=greatest(60,least(new.expiration_seconds,172800));
  end if;
 end if;
 return new;
end $$;
create trigger cap_view_once_deadline before update of view_once,expires_at on public.messages for each row execute function private.cap_view_once_deadline();
revoke all on function private.cap_view_once_deadline() from public,anon,authenticated;
revoke all on function private.attachment_deadline() from public,anon,authenticated;
commit;
