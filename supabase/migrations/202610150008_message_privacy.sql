begin;
-- Existing rows remain ordinary, server-readable messages. No encryption label
-- is inferred from HTTPS, storage policy, or this retention migration.
alter table public.conversations add column disappearing_seconds integer not null default 0
 check(disappearing_seconds=0 or disappearing_seconds between 60 and 2592000);
alter table public.messages add column expiration_seconds integer not null default 0
 check(expiration_seconds=0 or expiration_seconds between 60 and 2592000);
alter table public.messages add column expires_at timestamptz;
alter table public.messages add column view_once boolean not null default false;
alter table public.messages add column view_once_opened_at timestamptz;
alter table public.messages add constraint expiration_metadata check((expiration_seconds=0)=(expires_at is null));
alter table public.messages add constraint view_once_kind check(not view_once or kind in ('image','video'));
create index messages_expiration on public.messages(expires_at) where expires_at is not null;

-- Minimal tombstones prevent stale outbox retries resurrecting purged UUIDs.
create table public.message_tombstones (
 id uuid primary key, conversation_id uuid not null references public.conversations on delete cascade,
 removed_at timestamptz not null default now()
);
alter table public.message_tombstones enable row level security;
revoke all on public.message_tombstones from public,anon,authenticated;
grant select on public.message_tombstones to authenticated;
grant all on public.message_tombstones to service_role;
create policy tombstones_member on public.message_tombstones for select to authenticated using(private.is_member(conversation_id));
create table private.media_cleanup_jobs (
 bucket text not null check(bucket='chat-media'), path text not null,
 not_before timestamptz not null default now(), created_at timestamptz not null default now(), primary key(bucket,path)
);
create table public.privacy_events (
 id uuid primary key default gen_random_uuid(), conversation_id uuid not null references public.conversations on delete cascade,
 actor_id uuid references public.profiles on delete set null, action text not null check(action='expiration_policy'),
 duration_seconds integer not null, created_at timestamptz not null default now()
);
alter table public.privacy_events enable row level security;
revoke all on public.privacy_events from public,anon,authenticated;
grant select on public.privacy_events to authenticated;
grant all on public.privacy_events to service_role;
create policy privacy_events_member on public.privacy_events for select to authenticated using(private.is_member(conversation_id));

create function public.set_disappearing_policy(cid uuid, seconds integer) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform private.limit_operation('expiration_policy',10);
 if not private.is_member(cid) or (exists(select 1 from public.groups where conversation_id=cid) and not private.is_admin(cid))
    or exists(select 1 from public.conversation_members m where m.conversation_id=cid and private.blocked(m.user_id,auth.uid()))
 then raise exception 'Not permitted';end if;
 if seconds is null or (seconds<>0 and seconds not between 60 and 2592000) then raise exception 'Invalid duration';end if;
 update public.conversations set disappearing_seconds=seconds where id=cid;
 insert into public.privacy_events(conversation_id,actor_id,action,duration_seconds) values(cid,auth.uid(),'expiration_policy',seconds);
end $$;

create function private.message_privacy_insert() returns trigger language plpgsql security definer set search_path='' as $$
declare duration integer;begin
 if exists(select 1 from public.message_tombstones where id=new.id) then raise exception 'Message unavailable';end if;
 if new.reply_to is not null and not exists(select 1 from public.messages where id=new.reply_to and conversation_id=new.conversation_id and (expires_at is null or expires_at>now()) and not view_once) then raise exception 'Reply unavailable';end if;
 select disappearing_seconds into duration from public.conversations where id=new.conversation_id;
 new.expiration_seconds=duration;
 new.expires_at=case when duration>0 then new.created_at+make_interval(secs=>duration) end;
 return new;
end $$;
create trigger message_privacy_insert before insert on public.messages for each row execute function private.message_privacy_insert();
create or replace function private.message_member(mid uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.messages m where m.id=mid and private.is_member(m.conversation_id) and (m.expires_at is null or m.expires_at>now()))
$$;
drop policy messages_member on public.messages;
create policy messages_member on public.messages for select to authenticated using(private.is_member(conversation_id) and (expires_at is null or expires_at>now()));
drop policy attachments_member on public.message_attachments;
create policy attachments_member on public.message_attachments for select to authenticated using(private.message_member(message_id) and exists(select 1 from public.messages m where m.id=message_id and not m.view_once));
drop policy edits_owner on public.message_edits;
create policy edits_owner on public.message_edits for select to authenticated using(private.message_member(message_id) and exists(select 1 from public.messages m where m.id=message_id and m.sender_id=auth.uid()));

create function private.chat_object_readable(path text) returns boolean language sql stable security definer set search_path='' as $$
 select private.is_member(private.valid_uuid(split_part(path,'/',1))) and (
   exists(select 1 from public.groups g where g.avatar_path=path)
   or exists(select 1 from public.message_attachments a join public.messages m on m.id=a.message_id where a.object_path=path and m.deleted_at is null and not m.view_once and (m.expires_at is null or m.expires_at>now()))
   or (split_part(path,'/',2)=auth.uid()::text and not exists(select 1 from public.message_attachments a where a.object_path=path)
       and not exists(select 1 from private.media_cleanup_jobs j where j.path=path))
 )
$$;
revoke all on function private.chat_object_readable(text) from public,anon;
grant execute on function private.chat_object_readable(text) to authenticated;
drop policy chat_media_read on storage.objects;
create policy chat_media_read on storage.objects for select to authenticated using(bucket_id='chat-media' and private.chat_object_readable(name));

create or replace function public.conversation_list() returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(row_to_json(x) order by x.pinned desc,x.updated_at desc),'[]'::jsonb) from (
 select c.id,c.kind,c.updated_at,c.disappearing_seconds,m.pinned,m.archived,m.muted,
 coalesce(g.name,p.display_name,'Deleted account') as title,coalesce(g.avatar_path,p.avatar_path) as avatar_path,p.id as peer_id,
 last_message.preview,last_message.expires_at as preview_expires_at,
 (select count(*) from public.messages mm where mm.conversation_id=c.id and mm.created_at>m.last_read_at and mm.sender_id<>auth.uid() and mm.deleted_at is null and (mm.expires_at is null or mm.expires_at>now())) as unread
 from public.conversations c join public.conversation_members m on m.conversation_id=c.id and m.user_id=auth.uid()
 left join public.groups g on g.conversation_id=c.id
 left join public.conversation_members other on other.conversation_id=c.id and other.user_id<>auth.uid() and c.kind='direct'
 left join public.profiles p on p.id=other.user_id
 left join lateral (
  select case when mm.view_once then 'View-once media' else mm.body end as preview,mm.expires_at
  from public.messages mm where mm.conversation_id=c.id and mm.deleted_at is null and (mm.expires_at is null or mm.expires_at>now())
    and not exists(select 1 from public.message_hides h where h.message_id=mm.id and h.user_id=auth.uid())
  order by mm.created_at desc,mm.id desc limit 1
 )last_message on true
 )x
$$;

create function public.send_view_once_message(cid uuid, mid uuid, attachment jsonb, media_kind text) returns uuid
language plpgsql security definer set search_path='' as $$
declare existing public.messages;begin
 if not private.is_member(cid) or not exists(select 1 from public.conversations where id=cid and kind='direct') or media_kind not in ('image','video') then raise exception 'View-once unavailable';end if;
 select * into existing from public.messages where id=mid;
 if found then
  if existing.sender_id=auth.uid() and existing.conversation_id=cid and existing.view_once and (existing.expires_at is null or existing.expires_at>now()) then return mid;end if;
  raise exception 'Conflicting message ID';
 end if;
 perform public.send_message(cid,mid,'',media_kind,null,false,attachment);
 update public.messages set view_once=true,
  expiration_seconds=case when expiration_seconds=0 then 86400 else least(expiration_seconds,86400) end,
  expires_at=least(coalesce(expires_at,now()+interval '24 hours'),now()+interval '24 hours') where id=mid;
 return mid;
end $$;
-- Only the authenticated Edge Function's service credential can claim bytes.
-- Storage RLS never returns a view-once attachment, even to its uploader.
create function public.claim_view_once(mid uuid, viewer uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.messages; a public.message_attachments;begin
 select * into m from public.messages where id=mid for update;
 if not found or not m.view_once or m.view_once_opened_at is not null or m.deleted_at is not null or m.expires_at<=now()
    or viewer=m.sender_id or not private.is_member(m.conversation_id,viewer) or private.blocked(viewer,m.sender_id)
 then raise exception 'Media unavailable';end if;
 select * into a from public.message_attachments where message_id=mid;
 if not found then raise exception 'Media unavailable';end if;
 update public.messages set view_once_opened_at=now() where id=mid;
 insert into private.media_cleanup_jobs(bucket,path,not_before) values('chat-media',a.object_path,now()+interval '2 minutes') on conflict do nothing;
 return jsonb_build_object('object_path',a.object_path,'mime_type',a.mime_type,'size_bytes',a.size_bytes);
end $$;

create function public.expire_messages() returns integer language plpgsql security definer set search_path='' as $$
declare ids uuid[]; count_removed integer;begin
 select array_agg(id) into ids from (select id from public.messages where expires_at<=now() order by expires_at limit 500 for update skip locked)x;
 if ids is null then return 0;end if;
 insert into private.media_cleanup_jobs(bucket,path) select 'chat-media',object_path from public.message_attachments where message_id=any(ids) on conflict do nothing;
 insert into public.message_tombstones(id,conversation_id) select id,conversation_id from public.messages where id=any(ids) on conflict do nothing;
 delete from public.notification_jobs where kind='message' and resource_id=any(ids);
 delete from public.messages where id=any(ids);
 get diagnostics count_removed=row_count;
 return count_removed;
end $$;
create function public.retention_media_jobs() returns table(bucket text,path text) language sql stable security definer set search_path='' as $$
 select bucket,path from private.media_cleanup_jobs where not_before<=now() order by created_at limit 500
$$;
create function public.complete_media_cleanup(paths text[]) returns void language plpgsql security definer set search_path='' as $$
begin
 delete from public.message_attachments where object_path=any(paths) and message_id in(select id from public.messages where view_once and view_once_opened_at is not null);
 delete from public.media_validations where bucket='chat-media' and object_path=any(paths);
 delete from private.media_cleanup_jobs where bucket='chat-media' and path=any(paths);
end $$;
revoke all on function public.set_disappearing_policy(uuid,integer), public.send_view_once_message(uuid,uuid,jsonb,text) from public,anon;
grant execute on function public.set_disappearing_policy(uuid,integer), public.send_view_once_message(uuid,uuid,jsonb,text) to authenticated;
revoke all on function public.claim_view_once(uuid,uuid),public.expire_messages(),public.retention_media_jobs(),public.complete_media_cleanup(text[]) from public,anon,authenticated;
grant execute on function public.claim_view_once(uuid,uuid),public.expire_messages(),public.retention_media_jobs(),public.complete_media_cleanup(text[]) to service_role;
revoke execute on all functions in schema private from public,anon;
commit;
