\set ON_ERROR_STOP on
begin;
insert into auth.users(id) values('40000000-0000-0000-0000-000000000001'),('40000000-0000-0000-0000-000000000002'),('40000000-0000-0000-0000-000000000003');
set local role authenticated;
select set_config('request.jwt.claim.sub','40000000-0000-0000-0000-000000000001',true);
select public.create_direct('40000000-0000-0000-0000-000000000002') as cid \gset
select set_config('test.cid',:'cid',true);
select public.set_disappearing_policy(:'cid',86400);
select public.send_message(:'cid','41000000-0000-0000-0000-000000000001','expires');
do $$begin
 if not exists(select 1 from public.messages where expiration_seconds=86400 and expires_at=created_at+interval '24 hours') then raise exception 'policy not snapshotted';end if;
 begin perform public.set_disappearing_policy(current_setting('test.cid')::uuid,1);raise exception 'invalid duration accepted';exception when raise_exception then if sqlerrm='invalid duration accepted' then raise;end if;end;
end$$;
select public.set_disappearing_policy(:'cid',0);
select public.send_message(:'cid','41000000-0000-0000-0000-000000000002','permanent');
do $$begin if (select expiration_seconds from public.messages where id='41000000-0000-0000-0000-000000000001')<>86400 then raise exception 'old policy mutated';end if;end$$;
reset role;
update public.messages set expires_at=now()-interval '1 second' where id='41000000-0000-0000-0000-000000000001';
set local role authenticated;
do $$begin
 if exists(select 1 from public.messages where id='41000000-0000-0000-0000-000000000001') then raise exception 'expired body leaked before cleanup';end if;
 begin perform public.edit_message('41000000-0000-0000-0000-000000000001','expired edit');raise exception 'expired edit allowed';exception when raise_exception then if sqlerrm='expired edit allowed' then raise;end if;end;
 begin perform public.send_message(current_setting('test.cid')::uuid,'41000000-0000-0000-0000-000000000003','reply','text','41000000-0000-0000-0000-000000000001');raise exception 'expired reply allowed';exception when raise_exception then if sqlerrm='expired reply allowed' then raise;end if;end;
 begin perform public.expire_messages();raise exception 'client cleanup privilege';exception when insufficient_privilege then null;end;
end$$;
select set_config('request.jwt.claim.sub','40000000-0000-0000-0000-000000000003',true);
do $$begin
 begin perform public.set_disappearing_policy(current_setting('test.cid')::uuid,86400);raise exception 'outsider policy accepted';exception when raise_exception then if sqlerrm='outsider policy accepted' then raise;end if;end;
end$$;
reset role;
select public.expire_messages();
set local role authenticated;
select set_config('request.jwt.claim.sub','40000000-0000-0000-0000-000000000001',true);
do $$begin
 begin perform public.send_message(current_setting('test.cid')::uuid,'41000000-0000-0000-0000-000000000001','resurrect');raise exception 'tombstone restored';exception when raise_exception then if sqlerrm='tombstone restored' then raise;end if;end;
end$$;
-- View once: ordinary Storage access is denied, including to the uploader.
select :'cid'||'/40000000-0000-0000-0000-000000000001/once.png' as path \gset
select set_config('test.path',:'path',true);
insert into storage.objects(bucket_id,name,metadata) values('chat-media',:'path','{"size":8,"mimetype":"image/png"}');
reset role;
insert into public.media_validations values('chat-media',:'path','40000000-0000-0000-0000-000000000001','image/png',8,now());
set local role authenticated;
select public.send_view_once_message(:'cid','41000000-0000-0000-0000-000000000004',jsonb_build_object('object_path',:'path','filename','once.png'),'image');
-- Retry does not turn an existing normal message into view-once or extend TTL.
select public.send_view_once_message(:'cid','41000000-0000-0000-0000-000000000004',jsonb_build_object('object_path',:'path','filename','once.png'),'image');
do $$begin
 if exists(select 1 from storage.objects where name=current_setting('test.path')) then raise exception 'uploader view-once storage access';end if;
 if exists(select 1 from public.message_attachments where object_path=current_setting('test.path')) then raise exception 'view-once metadata leaked';end if;
 begin perform public.claim_view_once('41000000-0000-0000-0000-000000000004',auth.uid());raise exception 'direct claim privilege';exception when insufficient_privilege then null;end;
end$$;
reset role;
do $$begin
 begin perform public.claim_view_once('41000000-0000-0000-0000-000000000004','40000000-0000-0000-0000-000000000003');raise exception 'outsider claim';exception when raise_exception then if sqlerrm='outsider claim' then raise;end if;end;
 begin perform public.claim_view_once('41000000-0000-0000-0000-000000000004','40000000-0000-0000-0000-000000000001');raise exception 'sender claim';exception when raise_exception then if sqlerrm='sender claim' then raise;end if;end;
end$$;
select public.claim_view_once('41000000-0000-0000-0000-000000000004','40000000-0000-0000-0000-000000000002');
do $$begin
 begin perform public.claim_view_once('41000000-0000-0000-0000-000000000004','40000000-0000-0000-0000-000000000002');raise exception 'second claim';exception when raise_exception then if sqlerrm='second claim' then raise;end if;end;
 if not exists(select 1 from private.media_cleanup_jobs where path=current_setting('test.path')) then raise exception 'cleanup not queued';end if;
end$$;
set local role authenticated;
select set_config('request.jwt.claim.sub','40000000-0000-0000-0000-000000000002',true);
do $$begin if exists(select 1 from storage.objects where name=current_setting('test.path')) then raise exception 'recipient ordinary storage access';end if;end$$;
reset role;
select public.complete_media_cleanup(array[:'path']);
rollback;
\echo 'Expiration snapshot, RLS-before-cleanup, tombstones, view-once claims and cleanup authorization passed.'
