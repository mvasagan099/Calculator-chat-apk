-- Synthetic identities/codes only. Run against the disposable local test DB.
begin;
do $$begin
 if not exists(select 1 from public.profiles where id='12000000-0000-0000-0000-000000000099' and username='legacy_login' and display_name='Legacy preserved') then
 raise exception 'Pre-migration account changed';end if;
end $$;
select public.account_signup_intent('12000000-0000-0000-0000-000000000001','chosen_id','Chosen name',
 array(select md5(i::text)||md5(i::text) from generate_series(1,8)i));
insert into auth.users(id,email,raw_app_meta_data) values('12000000-0000-0000-0000-000000000002','random@accounts.owner.invalid',
 '{"calculator_signup_intent":"12000000-0000-0000-0000-000000000001"}');
do $$begin
 if not exists(select 1 from public.profiles where id='12000000-0000-0000-0000-000000000002' and username='chosen_id' and display_name='Chosen name') then raise exception 'Chosen identity lost';end if;
 if (select count(*) from private.account_recovery_codes where user_id='12000000-0000-0000-0000-000000000002')<>8 then raise exception 'Missing recovery';end if;
 if exists(select 1 from private.account_signup_intents where id='12000000-0000-0000-0000-000000000001') then raise exception 'Intent not consumed';end if;
end $$;
-- Duplicate identity must leave neither an Auth user nor half-created profile.
select public.account_signup_intent('12000000-0000-0000-0000-000000000003','chosen_id','Duplicate',
 array(select md5(i::text)||md5(i::text) from generate_series(1,8)i));
do $$begin
 begin
 insert into auth.users(id,raw_app_meta_data) values('12000000-0000-0000-0000-000000000004','{"calculator_signup_intent":"12000000-0000-0000-0000-000000000003"}');
 raise exception 'Duplicate accepted';
 exception when unique_violation then null;end;
 if exists(select 1 from auth.users where id='12000000-0000-0000-0000-000000000004') then raise exception 'Orphan Auth user';end if;
end $$;
-- Untrusted user metadata cannot set login identities or recovery credentials.
insert into auth.users(id,raw_user_meta_data) values('12000000-0000-0000-0000-000000000005','{"calculator_user_id":"chosen_id","calculator_signup_intent":"12000000-0000-0000-0000-000000000001"}');
do $$begin
 if exists(select 1 from public.profiles where id='12000000-0000-0000-0000-000000000005' and username='chosen_id') then raise exception 'Metadata forged identity';end if;
end $$;
-- Rate counter must persist even when limit is exceeded.
select public.account_auth_limit(repeat('a',64),1);
do $$begin
 if public.account_auth_limit(repeat('a',64),1) then raise exception 'Limiter bypass';end if;
 if (select attempts from private.account_auth_limits where scope=repeat('a',64))<>2 then raise exception 'Failed attempts lost';end if;
end $$;
-- Anonymous and authenticated users cannot resolve aliases, read codes, reset
-- passwords, approve recovery devices, or change their immutable login ID.
set local role anon;
do $$begin
 begin perform public.account_login_target('chosen_id');raise exception 'Alias leaked';exception when insufficient_privilege then null;end;
 begin perform public.account_claim_recovery('chosen_id',repeat('a',64),gen_random_uuid());raise exception 'Reset exposed';exception when insufficient_privilege then null;end;
end $$;
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub','12000000-0000-0000-0000-000000000002',true);
do $$begin
 begin perform public.account_login_target('chosen_id');raise exception 'Alias leaked';exception when insufficient_privilege then null;end;
 begin perform 1 from private.account_recovery_codes;raise exception 'Codes leaked';exception when insufficient_privilege then null;end;
 begin update public.profiles set username='taken' where id=auth.uid();raise exception 'Login ID changed';exception when insufficient_privilege then null;end;
end $$;
reset role;
-- One-time consumption plus old-session rejection and scoped recovery approval.
insert into auth.sessions(id,user_id,created_at) values('12000000-0000-0000-0000-000000000006','12000000-0000-0000-0000-000000000002',now()-interval '1 hour');
insert into private.device_access_policy(user_id) values('12000000-0000-0000-0000-000000000002');
do $$begin
 if public.account_claim_recovery('chosen_id',md5('1')||md5('1'),'12000000-0000-0000-0000-000000000007') is null then raise exception 'Valid recovery rejected';end if;
 if private.session_allowed_for('12000000-0000-0000-0000-000000000002','12000000-0000-0000-0000-000000000006') then raise exception 'Old session survived';end if;
 if public.account_claim_recovery('chosen_id',md5('1')||md5('1'),gen_random_uuid()) is not null then raise exception 'Code replay accepted';end if;
end $$;
insert into auth.sessions(id,user_id,created_at) values('12000000-0000-0000-0000-000000000008','12000000-0000-0000-0000-000000000002',clock_timestamp()+interval '1 second');
select public.account_finish_recovery('12000000-0000-0000-0000-000000000002','12000000-0000-0000-0000-000000000007',
 '12000000-0000-0000-0000-000000000008','12000000-0000-0000-0000-000000000009',array(select md5(i::text)||md5(i::text) from generate_series(11,18)i));
do $$begin
 if not private.session_allowed_for('12000000-0000-0000-0000-000000000002','12000000-0000-0000-0000-000000000008') then raise exception 'Recovery device not approved';end if;
 if private.session_allowed_for('12000000-0000-0000-0000-000000000002','12000000-0000-0000-0000-000000000006') then raise exception 'Old session revived';end if;
 if public.account_claim_recovery('chosen_id',md5('2')||md5('2'),gen_random_uuid()) is null then raise exception 'Lost-response fallback code was invalidated';end if;
 if public.account_claim_recovery('chosen_id',md5('3')||md5('3'),gen_random_uuid()) is not null then raise exception 'Parallel recovery claim accepted';end if;
 update private.account_recovery_state set claimed_at=now()-interval '16 minutes' where user_id='12000000-0000-0000-0000-000000000002';
 if public.account_claim_recovery('chosen_id',md5('2')||md5('2'),gen_random_uuid()) is not null then raise exception 'Stale used code replay accepted';end if;
 if public.account_claim_recovery('chosen_id',md5('3')||md5('3'),gen_random_uuid()) is null then raise exception 'Crashed-worker recovery blocked forever';end if;
end $$;
rollback;
