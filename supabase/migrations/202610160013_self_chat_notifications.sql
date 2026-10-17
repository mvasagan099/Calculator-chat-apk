begin;
-- A distinct key namespace uses the existing UNIQUE(direct_key) constraint to
-- serialize retries/concurrent requests without changing ordinary direct chats.
create function private.is_self_conversation(cid uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.conversations c where c.id=cid and c.kind='direct'
  and c.created_by=auth.uid() and c.direct_key='self:'||auth.uid()::text)
$$;
revoke all on function private.is_self_conversation(uuid) from public,anon,authenticated;

create function private.guard_self_member() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.conversations c where c.id=new.conversation_id and c.direct_key like 'self:%'
  and (c.kind<>'direct' or c.created_by is distinct from new.user_id or c.direct_key<>'self:'||new.user_id::text)) then
  raise exception 'Self conversation membership is immutable';
 end if;
 return new;
end $$;
revoke all on function private.guard_self_member() from public,anon,authenticated;
create trigger self_member_guard before insert or update of conversation_id,user_id on public.conversation_members
for each row execute function private.guard_self_member();

create or replace function public.create_direct(peer uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare cid uuid;begin
 perform private.require_session();
 if peer is distinct from auth.uid() then
  return private.device_guarded_create_direct(peer);
 end if;
 perform private.limit_operation('create_direct',20);
 insert into public.conversations(kind,direct_key,created_by)
 values('direct','self:'||auth.uid()::text,auth.uid())
 on conflict(direct_key) do update set direct_key=excluded.direct_key returning id into cid;
 insert into public.conversation_members(conversation_id,user_id) values(cid,auth.uid()) on conflict do nothing;
 return cid;
end $$;

create or replace function public.conversation_list() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;begin
 perform private.require_session();
 select coalesce(jsonb_agg(item || jsonb_build_object('is_self',private.is_self_conversation((item->>'id')::uuid)) ||
  case when private.is_self_conversation((item->>'id')::uuid) then
   jsonb_build_object('title','Message Yourself','peer_id',null,'unread',0)
  else '{}'::jsonb end order by ordinal_number),'[]'::jsonb) into result
 from jsonb_array_elements(private.device_guarded_conversation_list()) with ordinality as entries(item,ordinal_number);
 return result;
end $$;
-- send_message, attachment validation, receipts, RLS, cache and outbox are reused
-- unchanged. Their sender exclusion already suppresses self jobs/unread counts.
-- Both existing call entry points still require >=2 distinct members.

create function private.message_notification_target(mid uuid, recipient uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('conversation_id',m.conversation_id,'expires_at',m.expires_at)
 from public.messages m join public.conversation_members cm on cm.conversation_id=m.conversation_id and cm.user_id=recipient
 join public.user_settings s on s.user_id=recipient
 where m.id=mid and m.sender_id is not null and m.sender_id<>recipient and m.deleted_at is null
  and (m.expires_at is null or m.expires_at>now()) and not cm.muted and s.notifications
  and not private.blocked(m.sender_id,recipient)
  and not exists(select 1 from public.message_hides h where h.message_id=m.id and h.user_id=recipient)
$$;
revoke all on function private.message_notification_target(uuid,uuid) from public,anon,authenticated;

create function public.notification_message_target(mid uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 perform private.require_session();
 return private.message_notification_target(mid,auth.uid());
end $$;
create function public.message_push_target(mid uuid, recipient uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select private.message_notification_target(mid,recipient)
$$;
revoke all on function public.message_push_target(uuid,uuid) from public,anon,authenticated;
grant execute on function public.message_push_target(uuid,uuid) to service_role;

-- Optional real-version feed. Empty by default: messages never invent upgrades.
-- Only an owner-controlled server publication may populate this private table.
create table private.android_releases (
 id uuid primary key default gen_random_uuid(), build_number bigint not null check(build_number>0),
 package_id text not null check(package_id='app.calculatorspace.calculator_messenger'),
 abi text not null check(abi in ('arm64-v8a','armeabi-v7a','x86_64')),
 certificate_sha256 text not null check(certificate_sha256 ~ '^[0-9A-F]{64}$'),
 apk_sha256 text not null check(apk_sha256 ~ '^[0-9a-f]{64}$'),
 apk_url text not null check(apk_url ~ '^https://github[.]com/mvasagan099/Calculator-chat-apk/releases/download/[^?#[:space:]]+[.]apk$'),
 published_at timestamptz not null, published boolean not null default false,
 unique(package_id,certificate_sha256,abi,build_number)
);
alter table private.android_releases enable row level security;
revoke all on private.android_releases from public,anon,authenticated;
grant all on private.android_releases to service_role;
create function public.latest_android_release(target_abi text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;begin
 perform private.require_session();
 select to_jsonb(r) into result from private.android_releases r
 where r.published and r.published_at<=now() and r.abi=target_abi order by r.build_number desc limit 1;
 return result;
end $$;

revoke all on function public.create_direct(uuid),public.conversation_list(),public.notification_message_target(uuid),public.latest_android_release(text) from public,anon;
grant execute on function public.create_direct(uuid),public.conversation_list(),public.notification_message_target(uuid),public.latest_android_release(text) to authenticated;
commit;
