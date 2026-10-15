begin;
create table public.media_validations(bucket text not null,object_path text not null,user_id uuid not null references public.profiles on delete cascade,mime_type text not null,size_bytes bigint not null check(size_bytes between 1 and 26214400),created_at timestamptz not null default now(),primary key(bucket,object_path));
alter table public.media_validations enable row level security;
revoke all on public.media_validations from anon,authenticated;
grant all on public.media_validations to service_role;
create function private.check_avatar_validation() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.avatar_path is not null and new.avatar_path is distinct from old.avatar_path and not exists(select 1 from public.media_validations v where v.bucket='avatars' and v.object_path=new.avatar_path and v.user_id=new.id) then raise exception 'Avatar requires server validation';end if;
 return new;
end $$;
create trigger validate_avatar before update of avatar_path on public.profiles for each row execute function private.check_avatar_validation();
-- Every attached message must reference bytes validated by the trusted worker.
create function private.check_media_validation() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.media_validations v where v.bucket='chat-media' and v.object_path=new.object_path and v.user_id=auth.uid() and v.mime_type=new.mime_type and v.size_bytes=new.size_bytes) then raise exception 'Media requires server validation';end if;
 return new;
end $$;
create trigger validate_attachment before insert on public.message_attachments for each row execute function private.check_media_validation();
create function private.check_status_validation() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.object_path is not null and not exists(select 1 from public.media_validations v where v.bucket='status-media' and v.object_path=new.object_path and v.user_id=new.user_id) then raise exception 'Media requires server validation';end if;
 return new;
end $$;
create trigger validate_status before insert on public.status_updates for each row execute function private.check_status_validation();
create function public.storage_gc_candidates(owner_filter uuid default null) returns table(bucket text,path text) language sql stable security definer set search_path='' as $$
 select o.bucket_id,o.name from storage.objects o where o.bucket_id in ('chat-media','avatars','status-media') and (
 (owner_filter is not null and case when o.bucket_id='chat-media' then split_part(o.name,'/',2) else split_part(o.name,'/',1) end=owner_filter::text)
 or (owner_filter is null and (
  (o.bucket_id='status-media' and exists(select 1 from public.status_updates s where s.object_path=o.name and s.expires_at<now()))
  or (o.bucket_id='chat-media' and exists(select 1 from public.message_attachments a join public.messages m on m.id=a.message_id where a.object_path=o.name and m.deleted_at is not null))
  or (o.created_at<now()-interval '24 hours' and not exists(select 1 from public.media_validations v where v.bucket=o.bucket_id and v.object_path=o.name))
  or (o.created_at<now()-interval '24 hours' and not exists(select 1 from public.profiles p where p.id=private.valid_uuid(case when o.bucket_id='chat-media' then split_part(o.name,'/',2) else split_part(o.name,'/',1) end)))
  or (o.bucket_id='status-media' and o.created_at<now()-interval '25 hours' and not exists(select 1 from public.status_updates s where s.object_path=o.name))
  or (o.bucket_id='chat-media' and o.created_at<now()-interval '24 hours' and not exists(select 1 from public.message_attachments a where a.object_path=o.name) and not exists(select 1 from public.groups g where g.avatar_path=o.name))
  or (o.bucket_id='avatars' and o.created_at<now()-interval '24 hours' and not exists(select 1 from public.profiles p where p.avatar_path=o.name))
 ))) limit 500
$$;
create function public.purge_account(target uuid) returns void language plpgsql security definer set search_path='' as $$
declare cid uuid; successor uuid;begin
 for cid in select conversation_id from public.conversation_members where user_id=target and role='admin' loop
  if not exists(select 1 from public.conversation_members where conversation_id=cid and role='admin' and user_id<>target) then
   select user_id into successor from public.conversation_members where conversation_id=cid and user_id<>target order by joined_at limit 1;
   if successor is null then delete from public.conversations where id=cid;else update public.conversation_members set role='admin' where conversation_id=cid and user_id=successor;end if;
  end if;
 end loop;
 delete from public.message_edits where message_id in(select id from public.messages where sender_id=target);
 delete from public.message_attachments where message_id in(select id from public.messages where sender_id=target);
 update public.messages set body='',deleted_at=now() where sender_id=target;
end $$;
revoke all on function public.storage_gc_candidates(uuid),public.purge_account(uuid) from public,anon,authenticated;
grant execute on function public.storage_gc_candidates(uuid),public.purge_account(uuid) to service_role;
revoke execute on all functions in schema private from public,anon;
commit;
