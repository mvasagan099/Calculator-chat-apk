begin;
alter table public.user_settings add column online_visible boolean not null default true;
update public.user_settings set online_visible=last_seen_visible;
alter table public.user_settings add column photo_privacy text not null default 'everyone' check(photo_privacy in ('everyone','contacts','nobody'));
alter table public.user_settings add column invitation_privacy text not null default 'everyone' check(invitation_privacy in ('everyone','contacts','nobody'));
grant update(online_visible,photo_privacy,invitation_privacy) on public.user_settings to authenticated;
create policy online_publication_guard on realtime.messages as restrictive for insert to authenticated with check(
 extension<>'presence' or exists(select 1 from public.user_settings where user_id=auth.uid() and online_visible)
);
create function private.photo_visible(owner_id uuid) returns boolean language sql stable security definer set search_path='' as $$
 select owner_id=auth.uid() or (not private.blocked(owner_id,auth.uid()) and exists(select 1 from public.user_settings s where s.user_id=owner_id and (s.photo_privacy='everyone' or (s.photo_privacy='contacts' and exists(select 1 from public.contacts where owner_id=s.user_id and contact_id=auth.uid())))))
$$;
revoke all on function private.photo_visible(uuid) from public,anon;
grant execute on function private.photo_visible(uuid) to authenticated;
drop policy avatars_read on storage.objects;
create policy avatars_read on storage.objects for select to authenticated using(bucket_id='avatars' and (split_part(name,'/',1)=auth.uid()::text or (exists(select 1 from public.profiles p where p.avatar_path=name) and private.photo_visible(private.valid_uuid(split_part(name,'/',1))))));
create or replace function public.manage_group(cid uuid, action text, target uuid default null, value text default null) returns void language plpgsql security definer set search_path='' as $$
begin
 perform private.require_session();
 if action='invite' and not exists(select 1 from public.user_settings s where s.user_id=target and (s.invitation_privacy='everyone' or (s.invitation_privacy='contacts' and exists(select 1 from public.contacts c where c.owner_id=target and c.contact_id=auth.uid())))) then raise exception 'Invitations unavailable';end if;
 perform private.device_guarded_manage_group(cid,action,target,value);
end $$;
create or replace function public.edit_message(mid uuid,content text) returns void language plpgsql security definer set search_path='' as $$
begin
 perform private.require_session();
 if not private.message_member(mid) or exists(select 1 from public.messages where id=mid and view_once) then raise exception 'Message unavailable';end if;
 perform private.device_guarded_edit_message(mid,content);
end $$;
create or replace function public.send_message(cid uuid, mid uuid, content text, message_kind text default 'text', reply uuid default null, is_forwarded boolean default false, attachment jsonb default null) returns uuid language plpgsql security definer set search_path='' as $$
begin
 perform private.require_session();
 if exists(select 1 from public.messages where id=mid and expires_at<=now()) then raise exception 'Message unavailable';end if;
 return private.device_guarded_send_message(cid,mid,content,message_kind,reply,is_forwarded,attachment);
end $$;
-- Original guarded implementations remain private; no plaintext is copied to
-- event records and every new public routine retains the session check.
revoke execute on all functions in schema private from public,anon;
commit;
