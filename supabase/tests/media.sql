\set ON_ERROR_STOP on
begin;
insert into auth.users(id) values('20000000-0000-0000-0000-000000000001'),('20000000-0000-0000-0000-000000000002'),('20000000-0000-0000-0000-000000000003');
set local role authenticated;
select set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000001',true);
select public.create_direct('20000000-0000-0000-0000-000000000002') as cid \gset
select set_config('test.cid',:'cid',true);
select :'cid'||'/20000000-0000-0000-0000-000000000001/test.pdf' as path \gset
select set_config('test.path',:'path',true);
insert into storage.objects(bucket_id,name,metadata) values('chat-media',:'path','{"size":8,"mimetype":"application/pdf"}');
do $$begin
 begin perform public.send_message(current_setting('test.cid')::uuid,'30000000-0000-0000-0000-000000000001','','file',null,false,jsonb_build_object('object_path',current_setting('test.path'),'filename','test.pdf'));raise exception 'unvalidated attachment allowed';exception when raise_exception then if sqlerrm='unvalidated attachment allowed' then raise;end if;end;
end$$;
reset role;
insert into public.media_validations values('chat-media',:'path','20000000-0000-0000-0000-000000000001','application/pdf',8,now());
set local role authenticated;
select public.send_message(:'cid','30000000-0000-0000-0000-000000000001','','file',null,false,jsonb_build_object('object_path',:'path','filename','test.pdf'));
select set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000002',true);
do $$begin if not exists(select 1 from storage.objects where name=current_setting('test.path'))then raise exception 'member media denied';end if;end$$;
select set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000003',true);
do $$begin
 if exists(select 1 from storage.objects where name=current_setting('test.path'))then raise exception 'outsider media leaked';end if;
 begin insert into public.media_validations values('chat-media','forged',auth.uid(),'application/pdf',8,now());raise exception 'validation forgery allowed';exception when insufficient_privilege then null;end;
end$$;
select set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000001',true);
-- Forwarding into another conversation requires a new destination-owned,
-- independently validated object; a member of both cannot reuse the old path.
select public.create_direct('20000000-0000-0000-0000-000000000003') as destination \gset
select set_config('test.destination',:'destination',true);
do $$begin
 begin
  perform public.send_message(current_setting('test.destination')::uuid,'30000000-0000-0000-0000-000000000002','','file',null,true,jsonb_build_object('object_path',current_setting('test.path'),'filename','test.pdf'));
  raise exception 'cross-conversation path reuse allowed';
 exception when raise_exception then if sqlerrm='cross-conversation path reuse allowed' then raise;end if;end;
end$$;
select :'destination'||'/20000000-0000-0000-0000-000000000001/forwarded.pdf' as forwarded_path \gset
select set_config('test.forwarded_path',:'forwarded_path',true);
insert into storage.objects(bucket_id,name,metadata) values('chat-media',:'forwarded_path','{"size":8,"mimetype":"application/pdf"}');
reset role;
insert into public.media_validations values('chat-media',:'forwarded_path','20000000-0000-0000-0000-000000000001','application/pdf',8,now());
set local role authenticated;
select public.send_message(:'destination','30000000-0000-0000-0000-000000000002','','file',null,true,jsonb_build_object('object_path',:'forwarded_path','filename','forwarded.pdf'));
select set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000003',true);
do $$begin
 if not exists(select 1 from public.messages where id='30000000-0000-0000-0000-000000000002' and forwarded) then raise exception 'forward missing';end if;
 if not exists(select 1 from storage.objects where name=current_setting('test.forwarded_path')) then raise exception 'forwarded bytes unavailable';end if;
 if exists(select 1 from storage.objects where name=current_setting('test.path')) then raise exception 'source bytes leaked to destination member';end if;
end$$;
select set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000001',true);
select public.delete_message('30000000-0000-0000-0000-000000000001');
select set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000002',true);
do $$begin if exists(select 1 from storage.objects where name=current_setting('test.path'))then raise exception 'deleted attachment accessible';end if;end$$;
rollback;
\echo 'Validated-media ownership, storage isolation, forgery denial, destination-scoped forwarding and deleted-media denial passed.'
