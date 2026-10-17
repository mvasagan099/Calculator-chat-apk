\set ON_ERROR_STOP on
begin;
insert into auth.users(id) values('14000000-0000-0000-0000-000000000001'),('14000000-0000-0000-0000-000000000002'),('14000000-0000-0000-0000-000000000003');
set local role authenticated;
select set_config('request.jwt.claim.sub','14000000-0000-0000-0000-000000000001',true);
select public.create_direct(auth.uid()) as self_cid \gset
select set_config('test.self',:'self_cid',true);
select public.create_direct('14000000-0000-0000-0000-000000000002') as direct_cid \gset
select set_config('test.direct',:'direct_cid',true);
select public.create_group('Retention fixture') as group_cid \gset
select set_config('test.group',:'group_cid',true);
reset role;
-- Real worker hashes bytes. This SQL suite tests its trusted digest result and
-- server Storage timestamps, including duplicate/reupload origins.
do $$declare cid uuid; path text; n int=0; mime text;begin
 foreach cid in array array[current_setting('test.self')::uuid,current_setting('test.direct')::uuid,current_setting('test.group')::uuid] loop
  foreach mime in array array['image/jpeg','video/mp4'] loop
   n=n+1;path=cid::text||'/14000000-0000-0000-0000-000000000001/'||n;
   insert into storage.objects(bucket_id,name,metadata,created_at) values('chat-media',path,jsonb_build_object('size',8,'mimetype',mime),now()-interval '1 hour');
   perform public.record_chat_upload(path,lpad(n::text,64,'0'));
   insert into public.media_validations values('chat-media',path,'14000000-0000-0000-0000-000000000001',mime,8,now());
  end loop;
 end loop;
end $$;
set local role authenticated;
do $$declare cid uuid; path text; n int=0; kind text; mid uuid;begin
 foreach cid in array array[current_setting('test.self')::uuid,current_setting('test.direct')::uuid,current_setting('test.group')::uuid] loop
  foreach kind in array array['image','video'] loop
   n=n+1;path=cid::text||'/14000000-0000-0000-0000-000000000001/'||n;
   mid=public.send_message(cid,gen_random_uuid(),'Caption remains',kind,null,false,jsonb_build_object('object_path',path,'filename','fixture'));
   if not exists(select 1 from public.message_attachments where message_id=mid and media_expires_at=now()+interval '47 hours') then raise exception 'Wrong original upload deadline';end if;
   if not exists(select 1 from public.messages where id=mid and expires_at is null) then raise exception 'Text history expires';end if;
   if public.chat_media_deadline(path)->>'expires_at' is null then raise exception 'Authorized deadline missing';end if;
  end loop;
 end loop;
end $$;
reset role;
-- Documents, voice and persistent icons are intentionally older than 48 hours.
do $$declare ext text; mime text; path text;begin
 foreach ext in array array['pdf','ogg'] loop
  mime=case ext when 'pdf' then 'application/pdf' else 'audio/ogg' end;
  path=current_setting('test.self')||'/14000000-0000-0000-0000-000000000001/keep.'||ext;
  insert into storage.objects(bucket_id,name,metadata,created_at) values('chat-media',path,jsonb_build_object('size',8,'mimetype',mime),now()-interval '7 days');
  insert into public.media_validations values('chat-media',path,'14000000-0000-0000-0000-000000000001',mime,8,now());
 end loop;
 path=current_setting('test.group')||'/14000000-0000-0000-0000-000000000001/icons/persistent.jpg';
 insert into storage.objects(bucket_id,name,metadata,created_at) values('chat-media',path,'{"size":8,"mimetype":"image/jpeg"}',now()-interval '7 days');
 insert into public.media_validations values('chat-media',path,'14000000-0000-0000-0000-000000000001','image/jpeg',8,now());
end $$;
set local role authenticated;
select public.send_message(:'self_cid',gen_random_uuid(),'Keep document','file',null,false,jsonb_build_object('object_path',:'self_cid'||'/14000000-0000-0000-0000-000000000001/keep.pdf','filename','keep.pdf'));
select public.send_message(:'self_cid',gen_random_uuid(),'Keep voice','voice',null,false,jsonb_build_object('object_path',:'self_cid'||'/14000000-0000-0000-0000-000000000001/keep.ogg','filename','keep.ogg'));
select public.manage_group(:'group_cid','avatar',null,:'group_cid'||'/14000000-0000-0000-0000-000000000001/icons/persistent.jpg');
do $$begin
 begin perform public.manage_group(current_setting('test.group')::uuid,'avatar',null,current_setting('test.group')||'/14000000-0000-0000-0000-000000000001/5');raise exception 'Attachment promoted to icon';exception when raise_exception then if sqlerrm='Attachment promoted to icon' then raise;end if;end;
end $$;
-- Signing is denied even before expiry. Each authenticated read rechecks RLS.
select set_config('test.storage_operation','object.sign',true);
do $$begin if exists(select 1 from storage.objects where bucket_id='chat-media' and name not like '%/icons/%' and metadata->>'mimetype' like any(array['image/%','video/%'])) then raise exception 'Visual signed URL creation allowed';end if;end $$;
select set_config('test.storage_operation','object.get_authenticated',true);
select set_config('request.jwt.claim.sub','14000000-0000-0000-0000-000000000003',true);
do $$begin
 if exists(select 1 from storage.objects where bucket_id='chat-media') then raise exception 'Outsider reads media';end if;
 begin perform public.chat_media_deadline(current_setting('test.self')||'/14000000-0000-0000-0000-000000000001/1');raise exception 'Outsider deadline';exception when raise_exception then if sqlerrm='Outsider deadline' then raise;end if;end;
 begin perform public.queue_expired_chat_media();raise exception 'Cleanup exposed';exception when insufficient_privilege then null;end;
 begin perform public.record_chat_upload('forged',repeat('0',64));raise exception 'Provenance exposed';exception when insufficient_privilege then null;end;
end $$;
reset role;
-- Identical later upload/forward inherits earlier immutable fingerprint deadline.
insert into storage.objects(bucket_id,name,metadata) values('chat-media',:'self_cid'||'/14000000-0000-0000-0000-000000000001/duplicate','{"size":8,"mimetype":"image/jpeg"}');
select public.record_chat_upload(:'self_cid'||'/14000000-0000-0000-0000-000000000001/duplicate',lpad('1',64,'0'));
do $$begin
 if (select count(distinct deadline) from private.chat_upload_deadlines where digest=lpad('1',64,'0'))<>1 then raise exception 'Duplicate extended origin';end if;
end $$;
-- Simulate elapsed time with trusted fixture writes, not a client API.
update private.chat_upload_deadlines set deadline=now()-interval '1 second';
update public.message_attachments set media_expires_at=now()-interval '1 second' where mime_type like 'image/%' or mime_type like 'video/%';
set local role authenticated;
select set_config('request.jwt.claim.sub','14000000-0000-0000-0000-000000000001',true);
do $$begin
 if exists(select 1 from storage.objects where bucket_id='chat-media' and name not like '%/icons/%' and metadata->>'mimetype' like any(array['image/%','video/%'])) then raise exception 'Expired bytes leaked before cleanup';end if;
 if exists(select 1 from public.message_attachments where mime_type like 'image/%' or mime_type like 'video/%') then raise exception 'Expired metadata leaked';end if;
 if (select count(*) from public.messages where body='Caption remains')<>6 then raise exception 'Text lost at media expiry';end if;
 begin perform public.chat_media_deadline(current_setting('test.self')||'/14000000-0000-0000-0000-000000000001/1');raise exception 'Expired access';exception when raise_exception then if sqlerrm='Expired access' then raise;end if;end;
end $$;
reset role;
select public.queue_expired_chat_media();
select public.queue_expired_chat_media();
do $$begin if (select count(*) from private.media_cleanup_jobs)<>7 then raise exception 'Cleanup duplicate or orphan missed';end if;end $$;
-- Do not fake Storage deletion via SQL in production. The worker's separate
-- test proves Storage remove completes BEFORE this acknowledgement RPC.
select public.complete_media_cleanup(array(select path from private.media_cleanup_jobs));
select public.complete_media_cleanup(array(select name from storage.objects where bucket_id='chat-media'));
do $$begin
 if exists(select 1 from public.message_attachments where mime_type like 'image/%' or mime_type like 'video/%') or exists(select 1 from public.media_validations where bucket='chat-media' and object_path not like '%/icons/%' and mime_type like any(array['image/%','video/%'])) then raise exception 'Metadata retained';end if;
 if (select count(*) from public.messages where body='Caption remains')<>6 then raise exception 'Cleanup deleted text';end if;
 if (select count(*) from public.message_attachments where mime_type in ('application/pdf','audio/ogg'))<>2 then raise exception 'Nonvisual attachments removed';end if;
 if not exists(select 1 from storage.objects where name like '%/icons/persistent.jpg') then raise exception 'Persistent icon removed';end if;
 if not exists(select 1 from private.media_fingerprints) then raise exception 'Retry origins lost';end if;
end $$;
-- Revoked device and anonymous requests cannot obtain deadline grants.
insert into private.device_access_policy(user_id) values('14000000-0000-0000-0000-000000000001');
insert into public.account_devices(user_id,session_id,device_id,name,approved_at,revoked_at)
values('14000000-0000-0000-0000-000000000001','14200000-0000-0000-0000-000000000001',gen_random_uuid(),'revoked fixture',now(),now());
set local role authenticated;
select set_config('request.jwt.claims','{"session_id":"14200000-0000-0000-0000-000000000001"}',true);
do $$begin
 begin perform public.chat_media_deadline(current_setting('test.self')||'/14000000-0000-0000-0000-000000000001/1');raise exception 'Revoked device deadline allowed';exception when insufficient_privilege then null;end;
end $$;
reset role;
set local role anon;
do $$begin
 begin perform public.chat_media_deadline('untrusted');raise exception 'Anonymous media API allowed';exception when insufficient_privilege then null;end;
end $$;
reset role;
rollback;
\echo 'Upload timestamps, direct/group/self media, signing denial, RLS, duplicate origins, orphan cleanup and text preservation verified.'
