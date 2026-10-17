-- Synthetic identities and bytes metadata, disposable local test DB only.
begin;
insert into auth.users(id) values('13000000-0000-0000-0000-000000000001'),('13000000-0000-0000-0000-000000000002'),('13000000-0000-0000-0000-000000000003');
set local role authenticated;
select set_config('request.jwt.claim.sub','13000000-0000-0000-0000-000000000001',true);
select public.create_direct(auth.uid()) as self_cid \gset
select set_config('test.self_cid',:'self_cid',true);
select public.create_direct('13000000-0000-0000-0000-000000000002') as direct_cid \gset
select set_config('test.direct_cid',:'direct_cid',true);
do $$declare row jsonb;begin
 if public.create_direct(auth.uid())<>current_setting('test.self_cid')::uuid then raise exception 'Self retry duplicated';end if;
 if (select count(*) from public.conversation_members where conversation_id=current_setting('test.self_cid')::uuid)<>1 then raise exception 'Self membership wrong';end if;
 if (select count(*) from public.conversation_members where conversation_id=current_setting('test.direct_cid')::uuid)<>2 then raise exception 'Normal direct weakened';end if;
 select x into row from jsonb_array_elements(public.conversation_list()) x where x->>'id'=current_setting('test.self_cid');
 if row is null or row->>'title' is distinct from 'Message Yourself' or row->>'is_self' is distinct from 'true' or (row->>'unread')::int is distinct from 0 then raise exception 'Self list metadata incorrect';end if;
 begin perform public.begin_call(current_setting('test.self_cid')::uuid,false,gen_random_uuid());raise exception 'Self calling allowed';exception when raise_exception then if sqlerrm='Self calling allowed' then raise;end if;end;
 begin perform public.start_call(current_setting('test.self_cid')::uuid,false);raise exception 'Legacy self call allowed';exception when raise_exception then if sqlerrm='Legacy self call allowed' then raise;end if;end;
end $$;
select public.send_message(:'self_cid','13100000-0000-0000-0000-000000000001','A saved note');
select public.send_message(:'self_cid','13100000-0000-0000-0000-000000000002','A reply','text','13100000-0000-0000-0000-000000000001');
select public.edit_message('13100000-0000-0000-0000-000000000002','Edited reply');
do $$begin
 if not exists(select 1 from public.messages where id='13100000-0000-0000-0000-000000000002' and body='Edited reply' and reply_to='13100000-0000-0000-0000-000000000001') then raise exception 'Self reply/edit lost';end if;
end $$;
reset role;
-- The real validate-media worker is exercised by separate Edge tests; seed only
-- its trusted SQL result here to verify all existing attachment insertion gates.
do $$declare media_kind text; path text; mime text;begin
 foreach media_kind in array array['image','video','audio','voice','file'] loop
  path=current_setting('test.self_cid')||'/13000000-0000-0000-0000-000000000001/'||media_kind;
  mime=case media_kind when 'image' then 'image/jpeg' when 'video' then 'video/mp4' when 'file' then 'application/pdf' else 'audio/ogg' end;
  insert into storage.objects(bucket_id,name,metadata) values('chat-media',path,jsonb_build_object('size',8,'mimetype',mime));
  insert into public.media_validations(bucket,object_path,user_id,mime_type,size_bytes) values('chat-media',path,'13000000-0000-0000-0000-000000000001',mime,8);
  if media_kind in ('image','video') then insert into private.chat_upload_deadlines(path,uploaded_at,deadline) values(path,now(),now()+interval '48 hours');end if;
 end loop;
end $$;
set local role authenticated;
do $$declare media_kind text;begin
 foreach media_kind in array array['image','video','audio','voice','file'] loop
  perform public.send_message(current_setting('test.self_cid')::uuid,gen_random_uuid(),'',media_kind,null,false,
   jsonb_build_object('object_path',current_setting('test.self_cid')||'/13000000-0000-0000-0000-000000000001/'||media_kind,'filename',media_kind));
 end loop;
 if (select count(*) from public.messages where conversation_id=current_setting('test.self_cid')::uuid)<>7 then raise exception 'Self persistence failed';end if;
 if public.notification_message_target('13100000-0000-0000-0000-000000000001') is not null then raise exception 'Self notification target exposed';end if;
end $$;
select public.send_message(:'direct_cid','13100000-0000-0000-0000-000000000003','Incoming private text');
reset role;
do $$begin
 if exists(select 1 from public.notification_jobs j join public.messages m on m.id=j.resource_id where m.conversation_id=current_setting('test.self_cid')::uuid) then raise exception 'Self push job created';end if;
 if public.message_push_target('13100000-0000-0000-0000-000000000001','13000000-0000-0000-0000-000000000001') is not null then raise exception 'Worker self suppression failed';end if;
 begin insert into public.conversation_members(conversation_id,user_id) values(current_setting('test.self_cid')::uuid,'13000000-0000-0000-0000-000000000002');raise exception 'Self member forgery accepted';exception when raise_exception then if sqlerrm='Self member forgery accepted' then raise;end if;end;
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','13000000-0000-0000-0000-000000000002',true);
do $$begin
 if exists(select 1 from jsonb_array_elements(public.conversation_list()) x where x->>'id'=current_setting('test.self_cid')) then raise exception 'Self chat list leaked';end if;
 if public.create_direct(auth.uid())=current_setting('test.self_cid')::uuid then raise exception 'Self chats shared across accounts';end if;
 if exists(select 1 from public.messages where conversation_id=current_setting('test.self_cid')::uuid) then raise exception 'Self messages leaked';end if;
 if exists(select 1 from storage.objects where name like current_setting('test.self_cid')||'/%') then raise exception 'Self media leaked';end if;
 begin perform public.send_message(current_setting('test.self_cid')::uuid,gen_random_uuid(),'unauthorized');raise exception 'Outsider self send accepted';exception when raise_exception then if sqlerrm='Outsider self send accepted' then raise;end if;end;
 begin perform public.message_push_target('13100000-0000-0000-0000-000000000003',auth.uid());raise exception 'Service RPC exposed';exception when insufficient_privilege then null;end;
 if public.notification_message_target('13100000-0000-0000-0000-000000000003')->>'conversation_id' is distinct from current_setting('test.direct_cid') then raise exception 'Valid incoming target missing';end if;
end $$;
update public.conversation_members set muted=true where conversation_id=:'direct_cid' and user_id=auth.uid();
do $$begin if public.notification_message_target('13100000-0000-0000-0000-000000000003') is not null then raise exception 'Muted notification allowed';end if;end $$;
update public.conversation_members set muted=false where conversation_id=:'direct_cid' and user_id=auth.uid();
update public.user_settings set notifications=false where user_id=auth.uid();
do $$begin if public.notification_message_target('13100000-0000-0000-0000-000000000003') is not null then raise exception 'Disabled notifications ignored';end if;end $$;
update public.user_settings set notifications=true where user_id=auth.uid();
insert into public.user_blocks(blocker_id,blocked_id) values(auth.uid(),'13000000-0000-0000-0000-000000000001');
do $$begin if public.notification_message_target('13100000-0000-0000-0000-000000000003') is not null then raise exception 'Blocked notification allowed';end if;end $$;
delete from public.user_blocks where blocker_id=auth.uid();
insert into public.message_hides(message_id,user_id) values('13100000-0000-0000-0000-000000000003',auth.uid());
do $$begin if public.notification_message_target('13100000-0000-0000-0000-000000000003') is not null then raise exception 'Hidden notification allowed';end if;end $$;
delete from public.message_hides where user_id=auth.uid();
do $$begin
 if public.latest_android_release('arm64-v8a') is not null then raise exception 'Unpublished release invented';end if;
 begin perform 1 from private.android_releases;raise exception 'Release feed table exposed';exception when insufficient_privilege then null;end;
end $$;
reset role;
insert into private.android_releases(build_number,package_id,abi,certificate_sha256,apk_sha256,apk_url,published_at,published)
 values
 (2,'app.calculatorspace.calculator_messenger','arm64-v8a',repeat('A',64),repeat('b',64),'https://github.com/mvasagan099/Calculator-chat-apk/releases/download/fixture/fixture.apk',now(),false),
 (99,'app.calculatorspace.calculator_messenger','arm64-v8a',repeat('A',64),repeat('b',64),'https://github.com/mvasagan099/Calculator-chat-apk/releases/download/fixture/fixture.apk',now()+interval '1 day',true),
 (3,'app.calculatorspace.calculator_messenger','arm64-v8a',repeat('A',64),repeat('b',64),'https://github.com/mvasagan099/Calculator-chat-apk/releases/download/fixture/fixture.apk',now()-interval '1 second',true);
set local role authenticated;
do $$begin
 if (public.latest_android_release('arm64-v8a')->>'build_number')::int is distinct from 3 then raise exception 'Unpublished/future release surfaced';end if;
 if public.latest_android_release('armeabi-v7a') is not null then raise exception 'Foreign ABI release surfaced';end if;
end $$;
reset role;
update public.messages set expiration_seconds=60,expires_at=now()-interval '1 second' where id='13100000-0000-0000-0000-000000000003';
set local role authenticated;
do $$begin if public.notification_message_target('13100000-0000-0000-0000-000000000003') is not null then raise exception 'Expired notification allowed';end if;end $$;
reset role;
update public.messages set expiration_seconds=0,expires_at=null,deleted_at=now() where id='13100000-0000-0000-0000-000000000003';
set local role authenticated;
do $$begin if public.notification_message_target('13100000-0000-0000-0000-000000000003') is not null then raise exception 'Deleted notification allowed';end if;end $$;
select set_config('request.jwt.claim.sub','13000000-0000-0000-0000-000000000003',true);
do $$begin if public.notification_message_target('13100000-0000-0000-0000-000000000003') is not null then raise exception 'Outsider target exposed';end if;end $$;
select set_config('request.jwt.claim.sub','13000000-0000-0000-0000-000000000001',true);
select public.delete_message('13100000-0000-0000-0000-000000000001');
do $$begin if not exists(select 1 from public.messages where id='13100000-0000-0000-0000-000000000001' and deleted_at is not null and body='') then raise exception 'Self delete failed';end if;end $$;
reset role;
insert into private.device_access_policy(user_id) values('13000000-0000-0000-0000-000000000002');
insert into public.account_devices(user_id,session_id,device_id,name,approved_at,revoked_at) values('13000000-0000-0000-0000-000000000002','13200000-0000-0000-0000-000000000001',gen_random_uuid(),'revoked fixture',now(),now());
set local role authenticated;
select set_config('request.jwt.claim.sub','13000000-0000-0000-0000-000000000002',true);
select set_config('request.jwt.claims','{"session_id":"13200000-0000-0000-0000-000000000001"}',true);
do $$begin
 begin perform public.notification_message_target('13100000-0000-0000-0000-000000000003');raise exception 'Revoked target allowed';exception when insufficient_privilege then null;end;
 begin perform public.create_direct(auth.uid());raise exception 'Revoked self create allowed';exception when insufficient_privilege then null;end;
end $$;
reset role;
set local role anon;
do $$begin
 begin perform public.create_direct(gen_random_uuid());raise exception 'Anonymous self API exposed';exception when insufficient_privilege then null;end;
 begin perform public.notification_message_target(gen_random_uuid());raise exception 'Anonymous target exposed';exception when insufficient_privilege then null;end;
 begin perform public.latest_android_release('arm64-v8a');raise exception 'Anonymous release RPC exposed';exception when insufficient_privilege then null;end;
end $$;
reset role;
rollback;
\echo 'Self chat, attachments, notifications, isolation and device gates verified.'
