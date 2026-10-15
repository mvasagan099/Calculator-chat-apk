\set ON_ERROR_STOP on
begin;
insert into auth.users(id) values('00000000-0000-0000-0000-000000000001'),('00000000-0000-0000-0000-000000000002'),('00000000-0000-0000-0000-000000000003');
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);
select public.create_direct('00000000-0000-0000-0000-000000000002') as cid \gset
select set_config('test.cid',:'cid',true);
select public.send_message(:'cid','10000000-0000-0000-0000-000000000001','hello') as mid \gset
-- The same id must not create a duplicate during offline retries.
select public.send_message(:'cid',:'mid','hello');
do $$begin if (select count(*) from public.messages)<>1 then raise exception 'idempotency failed';end if;end$$;
select public.create_group('Test group') as gid \gset
select set_config('test.gid',:'gid',true);
select public.manage_group(:'gid','invite','00000000-0000-0000-0000-000000000002');
select id as iid from public.group_invitations where conversation_id=:'gid' \gset
select public.start_call(:'cid',true) as callid \gset
select set_config('test.callid',:'callid',true);
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',true);
do $$begin
 if exists(select 1 from public.messages) or exists(select 1 from public.conversations) or exists(select 1 from public.calls) then raise exception 'outsider read leaked';end if;
 begin perform public.send_message(current_setting('test.cid')::uuid,gen_random_uuid(),'intrude'); raise exception 'outsider send allowed';exception when raise_exception then if sqlerrm='outsider send allowed' then raise;end if;end;
 begin perform public.manage_group(current_setting('test.gid')::uuid,'invite','00000000-0000-0000-0000-000000000003');raise exception 'outsider group admin allowed';exception when raise_exception then if sqlerrm='outsider group admin allowed' then raise;end if;end;
 begin perform public.transition_call(current_setting('test.callid')::uuid,'accept');raise exception 'outsider call allowed';exception when raise_exception then if sqlerrm='outsider call allowed' then raise;end if;end;
 begin insert into public.messages(conversation_id,sender_id,body) values(current_setting('test.cid')::uuid,'00000000-0000-0000-0000-000000000001','spoof');raise exception 'direct write allowed';exception when insufficient_privilege then null;end;
end$$;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',true);
select public.accept_invitation(:'iid');
select public.ack_messages(:'cid',true);
do $$begin
 if (select count(*) from public.messages)<>1 then raise exception 'member cannot read';end if;
 if not exists(select 1 from public.message_receipts where read_at is not null) then raise exception 'receipt missing';end if;
 begin update public.conversation_members set role='admin' where user_id=auth.uid();raise exception 'self promotion allowed';exception when insufficient_privilege then null;end;
 begin perform public.edit_message('10000000-0000-0000-0000-000000000001','hijack');raise exception 'peer edit allowed';exception when raise_exception then if sqlerrm='peer edit allowed' then raise;end if;end;
 begin perform public.manage_group(current_setting('test.gid')::uuid,'name',null,'hijacked');raise exception 'member admin allowed';exception when raise_exception then if sqlerrm='member admin allowed' then raise;end if;end;
end$$;
select public.transition_call(:'callid','accept');
select public.transition_call(:'callid','end');
insert into public.user_blocks(blocker_id,blocked_id) values(auth.uid(),'00000000-0000-0000-0000-000000000001');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);
do $$begin
 begin perform public.send_message(current_setting('test.cid')::uuid,gen_random_uuid(),'blocked');raise exception 'block bypassed';exception when raise_exception then if sqlerrm='block bypassed' then raise;end if;end;
end$$;
select public.edit_message(:'mid','edited');
select public.delete_message(:'mid');
do $$begin if exists(select 1 from public.messages where body<>'') then raise exception 'delete retained body';end if;end$$;
reset role;
do $$begin
 if exists(select 1 from pg_tables where schemaname='public' and not rowsecurity) then raise exception 'missing RLS';end if;
 if exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef and has_function_privilege('anon',p.oid,'execute')) then raise exception 'anonymous RPC execution';end if;
end$$;
rollback;
\echo 'Authorization, idempotency, receipts, blocks, group roles and call transitions passed.'
