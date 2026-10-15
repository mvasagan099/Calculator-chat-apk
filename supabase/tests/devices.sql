\set ON_ERROR_STOP on
begin;
insert into auth.users(id) values('50000000-0000-0000-0000-000000000001'),('50000000-0000-0000-0000-000000000002');
set local role authenticated;
select set_config('request.jwt.claim.sub','50000000-0000-0000-0000-000000000001',true);
select set_config('request.jwt.claims','{"session_id":"51000000-0000-0000-0000-000000000001"}',true);
select public.create_direct('50000000-0000-0000-0000-000000000002') as cid \gset
select set_config('test.cid',:'cid',true);
select public.send_message(:'cid','52000000-0000-0000-0000-000000000001','private');
insert into storage.objects(bucket_id,name,metadata) values('chat-media',:'cid'||'/50000000-0000-0000-0000-000000000001/file.pdf','{"size":8,"mimetype":"application/pdf"}');
reset role;
select public.manage_account_device('50000000-0000-0000-0000-000000000001','51000000-0000-0000-0000-000000000001','enable','53000000-0000-0000-0000-000000000001','First device');
set local role authenticated;
select set_config('request.jwt.claims','{"session_id":"51000000-0000-0000-0000-000000000002"}',true);
do $$begin
 if exists(select 1 from public.messages) or exists(select 1 from storage.objects) then raise exception 'unapproved read';end if;
 begin insert into realtime.messages(id,extension,topic) values(1,'broadcast','conversation:'||current_setting('test.cid'));raise exception 'unapproved broadcast';exception when insufficient_privilege then null;end;
 begin perform public.send_message(current_setting('test.cid')::uuid,gen_random_uuid(),'bypass');raise exception 'unapproved RPC';exception when insufficient_privilege then null;end;
 begin perform private.device_guarded_send_message(current_setting('test.cid')::uuid,gen_random_uuid(),'bypass');raise exception 'unguarded original RPC';exception when insufficient_privilege then null;end;
 begin perform public.manage_account_device(auth.uid(),'51000000-0000-0000-0000-000000000002','enable',gen_random_uuid(),'self approve');raise exception 'admin RPC privilege';exception when insufficient_privilege then null;end;
end$$;
select public.request_device_approval('53000000-0000-0000-0000-000000000002','Second device');
select id as request_id,link_code as code from public.account_devices where session_id='51000000-0000-0000-0000-000000000002' \gset
select set_config('test.request',:'request_id',true);
select set_config('test.old_code',:'code',true);
reset role;
update public.account_devices set request_expires_at=now()-interval '1 second' where id=:'request_id';
set local role authenticated;
select public.request_device_approval('53000000-0000-0000-0000-000000000002','Second device');
select link_code as code from public.account_devices where id=:'request_id' \gset
do $$begin if exists(select 1 from public.account_devices where id=current_setting('test.request')::uuid and link_code=current_setting('test.old_code')) then raise exception 'expired code reused';end if;end$$;
reset role;
do $$begin
 begin perform public.manage_account_device('50000000-0000-0000-0000-000000000001','51000000-0000-0000-0000-000000000002','enable',gen_random_uuid(),'self approve');raise exception 'self approval bypass';exception when raise_exception then if sqlerrm='self approval bypass' then raise;end if;end;
end$$;
do $$begin
 begin perform public.manage_account_device('50000000-0000-0000-0000-000000000001','51000000-0000-0000-0000-000000000001','approve',null,null,current_setting('test.request')::uuid,'wrong code');raise exception 'wrong code approved';exception when raise_exception then if sqlerrm='wrong code approved' then raise;end if;end;
end$$;
select public.manage_account_device('50000000-0000-0000-0000-000000000001','51000000-0000-0000-0000-000000000001','approve',null,null,:'request_id',:'code');
set local role authenticated;
do $$begin if not exists(select 1 from public.messages) then raise exception 'approved device denied';end if;end$$;
select public.send_message(:'cid','52000000-0000-0000-0000-000000000002','approved');
insert into public.push_tokens(user_id,token,session_id) values(auth.uid(),'device-test-registration-token','51000000-0000-0000-0000-000000000001');
do $$begin if (select session_id from public.push_tokens where token='device-test-registration-token')<>'51000000-0000-0000-0000-000000000002' then raise exception 'push session spoof';end if;end$$;
reset role;
select public.manage_account_device('50000000-0000-0000-0000-000000000001','51000000-0000-0000-0000-000000000001','revoke',null,null,:'request_id');
set local role authenticated;
do $$begin
 if exists(select 1 from public.messages) or exists(select 1 from public.profiles) or exists(select 1 from storage.objects) then raise exception 'revoked table read';end if;
 begin perform public.conversation_list();raise exception 'revoked definer read';exception when insufficient_privilege then null;end;
 begin perform public.send_message(current_setting('test.cid')::uuid,gen_random_uuid(),'revoked');raise exception 'revoked RPC write';exception when insufficient_privilege then null;end;
 begin perform public.request_device_approval(gen_random_uuid(),'replace identity');raise exception 'revocation bypass by replacing device ID';exception when raise_exception then if sqlerrm='revocation bypass by replacing device ID' then raise;end if;end;
end$$;
reset role;
do $$begin if exists(select 1 from public.notification_tokens('50000000-0000-0000-0000-000000000001')) then raise exception 'revoked push delivery';end if;end$$;
select public.manage_account_device('50000000-0000-0000-0000-000000000001','51000000-0000-0000-0000-000000000001','revoke_others');
do $$begin if not exists(select 1 from public.account_devices where user_id='50000000-0000-0000-0000-000000000001' and session_id='51000000-0000-0000-0000-000000000001' and approved_at is not null and revoked_at is null) then raise exception 'revoke others removed acting device';end if;end$$;
rollback;
\echo 'Opt-in device approval, RPC/RLS guards, push binding, identity-replacement denial and revocation passed.'
