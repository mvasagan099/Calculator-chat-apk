begin;
-- Optional private, UNVERIFIED phone number. Never accept as recovery proof
-- until SMS OTP and ownership verification are separately implemented.
alter table private.account_signup_intents add column if not exists recovery_phone_e164 text;
alter table private.account_recovery_state add column if not exists recovery_phone_e164 text;
alter table private.account_signup_intents add constraint signup_phone_e164_chk
  check (recovery_phone_e164 is null or recovery_phone_e164 ~ '^\+[1-9][0-9]{7,14}$');
alter table private.account_recovery_state add constraint recovery_phone_e164_chk
  check (recovery_phone_e164 is null or recovery_phone_e164 ~ '^\+[1-9][0-9]{7,14}$');

-- Preserve four-argument signup RPC for already installed APKs.
create function public.account_signup_intent(
  intent uuid, login_id text, display_name text, hashes text[], recovery_phone text
) returns void language plpgsql security definer set search_path='' as $$
begin
  if recovery_phone is not null and recovery_phone !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'Invalid mobile number';
  end if;
  perform public.account_signup_intent(intent,login_id,display_name,hashes);
  update private.account_signup_intents set recovery_phone_e164=recovery_phone where id=intent;
end $$;
revoke all on function public.account_signup_intent(uuid,text,text,text[],text) from public,anon,authenticated;
grant execute on function public.account_signup_intent(uuid,text,text,text[],text) to service_role;

create or replace function private.new_user() returns trigger
language plpgsql security definer set search_path='' as $$
declare signup private.account_signup_intents;
begin
  if new.raw_app_meta_data ? 'calculator_signup_intent' then
    delete from private.account_signup_intents
      where id=(new.raw_app_meta_data->>'calculator_signup_intent')::uuid
        and expires_at>now() returning * into signup;
    if signup.id is null then raise exception 'Registration intent unavailable'; end if;
    insert into public.profiles(id,username,display_name)
      values(new.id,signup.login_id,signup.display_name);
    insert into private.account_recovery_state(user_id,recovery_phone_e164)
      values(new.id,signup.recovery_phone_e164);
    insert into private.account_recovery_codes(user_id,digest)
      select new.id,unnest(signup.recovery_hashes);
  else
    insert into public.profiles(id,username,display_name) values(
      new.id,'u_'||left(md5(new.id::text),26),
      left(coalesce(nullif(new.raw_user_meta_data->>'display_name',''),'New user'),80)
    );
  end if;
  insert into public.user_settings(user_id) values(new.id);return new;
end $$;
commit;
