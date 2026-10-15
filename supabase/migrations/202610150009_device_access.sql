begin;
-- Account-session approval is separate from cryptographic device identity.
-- Legacy accounts retain access until their owner explicitly enables approval.
create table private.device_access_policy(user_id uuid primary key references public.profiles on delete cascade, enabled_at timestamptz not null default now());
create table private.device_access_events(id uuid primary key default gen_random_uuid(),user_id uuid not null references public.profiles on delete cascade,session_id uuid not null,action text not null,target_id uuid,created_at timestamptz not null default now());
create table public.account_devices (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles on delete cascade,
 session_id uuid not null, device_id uuid not null, name text not null check(length(name) between 1 and 80),
 link_code text not null default encode(extensions.gen_random_bytes(12),'hex'),
 requested_at timestamptz not null default now(), request_expires_at timestamptz not null default now()+interval '10 minutes',
 approved_at timestamptz, revoked_at timestamptz, last_seen_at timestamptz not null default now(), unique(user_id,session_id)
);
alter table public.account_devices enable row level security;
revoke all on public.account_devices from public,anon,authenticated;
grant select on public.account_devices to authenticated;
grant all on public.account_devices to service_role;
create function private.jwt_session() returns uuid language sql stable set search_path='' as $$
 select private.valid_uuid(auth.jwt()->>'session_id')
$$;
create function private.session_allowed_for(owner_id uuid, sid uuid) returns boolean language sql stable security definer set search_path='' as $$
 select owner_id is not null and (
   not exists(select 1 from private.device_access_policy where user_id=owner_id)
   or exists(select 1 from public.account_devices where user_id=owner_id and session_id=sid and approved_at is not null and revoked_at is null)
 ) and not exists(select 1 from public.account_devices where user_id=owner_id and session_id=sid and revoked_at is not null)
$$;
create function private.session_allowed() returns boolean language sql stable security definer set search_path='' as $$
 select private.session_allowed_for(auth.uid(),private.jwt_session())
$$;
create function private.require_session() returns void language plpgsql security definer set search_path='' as $$
begin if not private.session_allowed() then raise exception 'Device approval required' using errcode='42501';end if;end $$;
revoke all on function private.jwt_session(),private.session_allowed_for(uuid,uuid),private.session_allowed(),private.require_session() from public,anon,authenticated;
grant execute on function private.jwt_session(),private.session_allowed() to authenticated;
create policy devices_owner on public.account_devices for select to authenticated using(user_id=auth.uid() and (private.session_allowed() or session_id=private.jwt_session()));

-- RLS is additive and restrictive: none of the existing membership checks are
-- removed or broadened. Supabase service-role workers retain trusted access.
do $$ declare t record; begin
 for t in select tablename from pg_tables where schemaname='public' and tablename<>'account_devices' loop
  execute format('create policy device_access_guard on public.%I as restrictive for all to authenticated using(private.session_allowed()) with check(private.session_allowed())',t.tablename);
 end loop;
end $$;
create policy device_access_guard on storage.objects as restrictive for all to authenticated using(private.session_allowed()) with check(private.session_allowed());
create policy device_access_guard on realtime.messages as restrictive for all to authenticated using(private.session_allowed()) with check(private.session_allowed());

-- Existing SECURITY DEFINER RPCs bypass table RLS. Preserve signatures/defaults
-- and implementations behind guarded entry points; the originals become
-- private and non-executable by clients. No data or existing policies are reset.
do $$ declare f record; arguments text; result_type text; call_args text; original_name text; statement text; begin
 for f in select p.oid,p.proname,p.prorettype,p.proargnames,p.pronargs,p.proretset,
    pg_get_function_arguments(p.oid) as args,pg_get_function_identity_arguments(p.oid) as identity_args,
    pg_get_function_result(p.oid) as result
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prokind='f' and has_function_privilege('authenticated',p.oid,'execute')
 loop
  if f.proretset then raise exception 'Unexpected client set-returning RPC; review wrapper';end if;
  select string_agg(format('$%s',i),',') into call_args from generate_series(1,f.pronargs)i;
  call_args=coalesce(call_args,''); original_name='device_guarded_'||f.proname;
  execute format('alter function public.%I(%s) set schema private',f.proname,f.identity_args);
  execute format('alter function private.%I(%s) rename to %I',f.proname,f.identity_args,original_name);
  execute format('revoke all on function private.%I(%s) from public,anon,authenticated',original_name,f.identity_args);
  statement=case when f.prorettype='void'::regtype then format('perform private.%I(%s); return;',original_name,call_args)
     else format('return private.%I(%s);',original_name,call_args) end;
  execute format('create function public.%I(%s) returns %s language plpgsql security definer set search_path='''' as %L',
     f.proname,f.args,f.result,'begin perform private.require_session(); '||statement||' end');
  execute format('revoke all on function public.%I(%s) from public,anon',f.proname,f.identity_args);
  execute format('grant execute on function public.%I(%s) to authenticated',f.proname,f.identity_args);
 end loop;
end $$;

create function public.device_access_status() returns jsonb language plpgsql security definer set search_path='' as $$
declare row public.account_devices;begin
 if auth.uid() is null then raise exception 'Authentication required';end if;
 select * into row from public.account_devices where user_id=auth.uid() and session_id=private.jwt_session();
 return jsonb_build_object('enforced',exists(select 1 from private.device_access_policy where user_id=auth.uid()),
   'authorized',private.session_allowed(),'session_id',private.jwt_session(),'device',case when row.id is null then null else to_jsonb(row) end);
end $$;
create function public.request_device_approval(device uuid, device_name text) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 perform private.limit_operation('device_request',10);
 if private.jwt_session() is null or length(trim(device_name)) not between 1 and 80 then raise exception 'Invalid device request';end if;
 if exists(select 1 from public.account_devices where user_id=auth.uid() and session_id=private.jwt_session() and revoked_at is not null) then raise exception 'Session revoked';end if;
 insert into public.account_devices(user_id,session_id,device_id,name) values(auth.uid(),private.jwt_session(),device,trim(device_name))
 on conflict(user_id,session_id) do update set name=excluded.name,last_seen_at=now(),
 link_code=case when public.account_devices.approved_at is null and public.account_devices.request_expires_at<=now() then encode(extensions.gen_random_bytes(12),'hex') else public.account_devices.link_code end,
 request_expires_at=case when public.account_devices.approved_at is null and public.account_devices.request_expires_at<=now() then now()+interval '10 minutes' else public.account_devices.request_expires_at end;
 return public.device_access_status();
end $$;
create function public.device_heartbeat() returns void language plpgsql security definer set search_path='' as $$
begin
 perform private.require_session();
 update public.account_devices set last_seen_at=now() where user_id=auth.uid() and session_id=private.jwt_session();
end $$;
create function public.revoke_this_device() returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or private.jwt_session() is null then return;end if;
 update public.account_devices set revoked_at=coalesce(revoked_at,now()) where user_id=auth.uid() and session_id=private.jwt_session();
 delete from public.push_tokens where user_id=auth.uid() and session_id=private.jwt_session();
end $$;

alter table public.push_tokens add column session_id uuid;
create function private.bind_push_session() returns trigger language plpgsql security definer set search_path='' as $$
begin new.session_id=private.jwt_session();return new;end $$;
create trigger bind_push_session before insert or update on public.push_tokens for each row execute function private.bind_push_session();
create function public.notification_tokens(recipient uuid) returns table(token text) language sql stable security definer set search_path='' as $$
 select p.token from public.push_tokens p where p.user_id=recipient and private.session_allowed_for(recipient,p.session_id)
$$;
-- This service-only operation is called only after device-security verifies
-- both the current Auth user and their password using an isolated Auth client.
create function public.manage_account_device(actor uuid, actor_session uuid, operation text, device uuid default null, device_name text default null, target uuid default null, code text default null) returns void
language plpgsql security definer set search_path='' as $$
begin
 if actor is null or actor_session is null then raise exception 'Session required';end if;
 -- Serialize activation/approval/revocation to avoid cross-session races.
 perform pg_advisory_xact_lock(hashtextextended(actor::text,1));
 if not private.session_allowed_for(actor,actor_session) then raise exception 'Approved device required';end if;
 if operation='enable' then
   if device is null or length(trim(device_name)) not between 1 and 80 then raise exception 'Device identity required';end if;
   insert into private.device_access_policy(user_id) values(actor) on conflict do nothing;
   insert into public.account_devices(user_id,session_id,device_id,name,approved_at) values(actor,actor_session,device,trim(device_name),now())
    on conflict(user_id,session_id) do update set approved_at=now(),name=excluded.name;
 elsif operation='approve' then
   update public.account_devices set approved_at=now() where id=target and user_id=actor and session_id<>actor_session
    and revoked_at is null and approved_at is null and request_expires_at>now() and link_code=code;
   if not found then raise exception 'Approval unavailable';end if;
 elsif operation='revoke' then
   update public.account_devices set revoked_at=coalesce(revoked_at,now()) where id=target and user_id=actor and session_id<>actor_session;
   if not found then raise exception 'Device unavailable';end if;
 elsif operation='revoke_others' then
   update public.account_devices set revoked_at=coalesce(revoked_at,now()) where user_id=actor and session_id<>actor_session;
 else raise exception 'Invalid operation';end if;
 insert into private.device_access_events(user_id,session_id,action,target_id) values(actor,actor_session,operation,target);
 delete from public.push_tokens p where p.user_id=actor and exists(select 1 from public.account_devices d where d.user_id=actor and d.session_id=p.session_id and d.revoked_at is not null);
end $$;
revoke all on function public.device_access_status(),public.request_device_approval(uuid,text),public.device_heartbeat(),public.revoke_this_device() from public,anon;
grant execute on function public.device_access_status(),public.request_device_approval(uuid,text),public.device_heartbeat(),public.revoke_this_device() to authenticated;
revoke all on function public.manage_account_device(uuid,uuid,text,uuid,text,uuid,text),public.notification_tokens(uuid) from public,anon,authenticated;
grant execute on function public.manage_account_device(uuid,uuid,text,uuid,text,uuid,text),public.notification_tokens(uuid) to service_role;
create function public.begin_device_security() returns void language plpgsql security definer set search_path='' as $$
begin perform private.require_session();perform private.limit_operation('device_security',5);end $$;
revoke all on function public.begin_device_security() from public,anon;
grant execute on function public.begin_device_security() to authenticated;
revoke execute on all functions in schema private from public,anon;
commit;
