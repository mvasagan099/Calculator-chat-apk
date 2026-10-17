begin;
-- Public profiles.username is the immutable login ID, NOT auth.users.id.
-- All new Auth administration below is callable only by the Edge service role.
revoke update(username) on public.profiles from authenticated;

create table private.account_signup_intents (
 id uuid primary key, login_id text not null check(login_id ~ '^[a-z0-9_]{3,30}$'),
 display_name text not null check(length(display_name) between 1 and 80),
 recovery_hashes text[] not null check(cardinality(recovery_hashes)=8),
 expires_at timestamptz not null default now()+interval '5 minutes'
);
create table private.account_recovery_state (
 user_id uuid primary key references public.profiles on delete cascade,
 session_cutoff timestamptz, claim uuid, claimed_at timestamptz
);
create table private.account_recovery_codes (
 user_id uuid references public.profiles on delete cascade,
 digest text not null check(digest ~ '^[0-9a-f]{64}$'), used_at timestamptz,
 primary key(user_id,digest)
);
create table private.account_auth_limits (
 scope text not null, bucket timestamptz not null, attempts integer not null,
 primary key(scope,bucket)
);
alter table private.account_signup_intents enable row level security;
alter table private.account_recovery_state enable row level security;
alter table private.account_recovery_codes enable row level security;
alter table private.account_auth_limits enable row level security;
revoke all on private.account_signup_intents,private.account_recovery_state,
 private.account_recovery_codes,private.account_auth_limits from public,anon,authenticated;

create function public.account_auth_limit(scope_key text, maximum integer) returns boolean
language plpgsql security definer set search_path='' as $$
declare n integer;begin
 if scope_key !~ '^[0-9a-f]{64}$' or maximum not between 1 and 100 then raise exception 'Invalid limiter';end if;
 insert into private.account_auth_limits values(scope_key,date_trunc('hour',now()),1)
 on conflict(scope,bucket) do update set attempts=least(private.account_auth_limits.attempts+1,101) returning attempts into n;
 -- Return rather than raise: failed attempts must commit and count.
 delete from private.account_auth_limits where bucket<now()-interval '2 hours';
 delete from private.account_signup_intents where expires_at<now();
 return n<=maximum;
end $$;

create function public.account_login_target(login_id text) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',p.id,'alias',u.email) from public.profiles p
 join auth.users u on u.id=p.id where p.username=login_id
$$;

create function public.account_signup_intent(intent uuid, login_id text, display_name text, hashes text[]) returns void
language plpgsql security definer set search_path='' as $$
begin
 if cardinality(hashes)<>8 or exists(select 1 from unnest(hashes) h where h !~ '^[0-9a-f]{64}$') then raise exception 'Invalid recovery codes';end if;
 insert into private.account_signup_intents(id,login_id,display_name,recovery_hashes)
 values(intent,login_id,display_name,hashes);
end $$;
create function public.account_discard_intent(intent uuid) returns void
language sql security definer set search_path='' as $$
 delete from private.account_signup_intents where id=intent
$$;

-- Supabase Admin createUser + this trigger form ONE PostgreSQL transaction.
-- A duplicate profiles.username rolls back Auth user, profile and recovery rows.
-- Client-editable user_metadata is never trusted for login identity.
create or replace function private.new_user() returns trigger language plpgsql security definer set search_path='' as $$
declare signup private.account_signup_intents;begin
 if new.raw_app_meta_data ? 'calculator_signup_intent' then
   delete from private.account_signup_intents
    where id=(new.raw_app_meta_data->>'calculator_signup_intent')::uuid and expires_at>now()
    returning * into signup;
   if signup.id is null then raise exception 'Registration intent unavailable';end if;
   insert into public.profiles(id,username,display_name) values(new.id,signup.login_id,signup.display_name);
   insert into private.account_recovery_state(user_id) values(new.id);
   insert into private.account_recovery_codes(user_id,digest) select new.id,unnest(signup.recovery_hashes);
 else
   -- Existing signup integrations remain compatible until separately disabled.
   insert into public.profiles(id,username,display_name) values(new.id,'u_'||left(md5(new.id::text),26),left(coalesce(nullif(new.raw_user_meta_data->>'display_name',''),'New user'),80));
 end if;
 insert into public.user_settings(user_id) values(new.id);return new;
end $$;

-- Invalidate old JWTs immediately at the RLS/RPC layer, even before expiry.
-- Preserve the existing device-policy implementation and wrap it, never bypass it.
create function private.device_policy_session_allowed_for(owner_id uuid,sid uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select owner_id is not null and (
   not exists(select 1 from private.device_access_policy where user_id=owner_id)
   or exists(select 1 from public.account_devices where user_id=owner_id and session_id=sid and approved_at is not null and revoked_at is null)
 ) and not exists(select 1 from public.account_devices where user_id=owner_id and session_id=sid and revoked_at is not null)
$$;
-- Replace in place to preserve the function OID used by existing dependencies.
create or replace function private.session_allowed_for(owner_id uuid,sid uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select private.device_policy_session_allowed_for(owner_id,sid) and not exists(
  select 1 from private.account_recovery_state r where r.user_id=owner_id and (
   r.claim is not null or (r.session_cutoff is not null and not exists(
    select 1 from auth.sessions s where s.id=sid and s.user_id=owner_id and s.created_at>r.session_cutoff))))
$$;
revoke all on function private.device_policy_session_allowed_for(uuid,uuid),private.session_allowed_for(uuid,uuid) from public,anon,authenticated;
grant execute on function private.session_allowed_for(uuid,uuid) to authenticated;

create function public.account_rotate_codes(owner_id uuid, sid uuid, hashes text[]) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(hashtextextended(owner_id::text,12));
 if sid is null or not private.session_allowed_for(owner_id,sid) or cardinality(hashes)<>8 or
 exists(select 1 from unnest(hashes) h where h !~ '^[0-9a-f]{64}$') then raise exception 'Recovery update unavailable';end if;
 insert into private.account_recovery_state(user_id) values(owner_id) on conflict do nothing;
 delete from private.account_recovery_codes where user_id=owner_id;
 insert into private.account_recovery_codes(user_id,digest) select owner_id,unnest(hashes);
end $$;

create function public.account_claim_recovery(login_id text, code_hash text, claim_id uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare owner_id uuid;begin
 select id into owner_id from public.profiles where username=login_id;
 if owner_id is null then return null;end if;
 perform pg_advisory_xact_lock(hashtextextended(owner_id::text,12));
 -- A crashed Edge worker cannot hold the account forever. Used codes stay
 -- consumed; only another unused code can replace a stale claim after 15 min.
 if exists(select 1 from private.account_recovery_state where user_id=owner_id and claim is not null and claimed_at>now()-interval '15 minutes') then return null;end if;
 update private.account_recovery_codes set used_at=now() where user_id=owner_id and digest=code_hash and used_at is null;
 if not found then return null;end if;
 update private.account_recovery_state set claim=claim_id,claimed_at=now(),session_cutoff=clock_timestamp() where user_id=owner_id;
 return owner_id;
end $$;
create function public.account_cancel_recovery(owner_id uuid, claim_id uuid) returns void
language sql security definer set search_path='' as $$
 update private.account_recovery_state set claim=null,claimed_at=null where user_id=owner_id and claim=claim_id
 -- The used code and old-session cutoff are intentionally never rolled back.
$$;
create function public.account_finish_recovery(owner_id uuid,claim_id uuid,sid uuid,device uuid,hashes text[]) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(hashtextextended(owner_id::text,12));
 if device is null or cardinality(hashes)<>8 or exists(select 1 from unnest(hashes) h where h !~ '^[0-9a-f]{64}$') then raise exception 'Invalid recovery';end if;
 if not exists(select 1 from private.account_recovery_state r join auth.sessions s on s.user_id=r.user_id
   where r.user_id=owner_id and r.claim=claim_id and s.id=sid and s.created_at>r.session_cutoff) then raise exception 'Recovery session unavailable';end if;
 update public.account_devices set revoked_at=coalesce(revoked_at,now()) where user_id=owner_id;
 -- A valid one-time recovery code authorizes only this fresh session/device.
 insert into public.account_devices(user_id,session_id,device_id,name,approved_at)
 values(owner_id,sid,device,'Recovered Android device',now());
 delete from public.push_tokens where user_id=owner_id;
 -- Keep other UNUSED codes until an explicit password-proven rotation. If the
 -- response is lost after commit, the owner can retry with another saved code.
 delete from private.account_recovery_codes where user_id=owner_id and used_at is not null;
 insert into private.account_recovery_codes(user_id,digest) select owner_id,unnest(hashes);
 update private.account_recovery_state set claim=null,claimed_at=null where user_id=owner_id;
 insert into private.device_access_events(user_id,session_id,action) values(owner_id,sid,'code_recovery');
end $$;

-- No service-only entry point is exposed to an anonymous or authenticated JWT.
do $$ declare f record;begin
 for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname in ('account_auth_limit','account_login_target','account_signup_intent','account_discard_intent','account_rotate_codes','account_claim_recovery','account_cancel_recovery','account_finish_recovery') loop
 execute format('revoke all on function %s from public,anon,authenticated',f.signature);
 execute format('grant execute on function %s to service_role',f.signature);
 end loop;
end $$;
commit;
