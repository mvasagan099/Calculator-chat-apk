\set ON_ERROR_STOP on
begin;
insert into auth.users(id) values('00000000-0000-0000-0000-000000000001'),('00000000-0000-0000-0000-000000000002'),('00000000-0000-0000-0000-000000000003');
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);
select public.create_direct('00000000-0000-0000-0000-000000000002') as cid \gset
select public.start_call(:'cid',true) as callid \gset
select set_config('test.callid',:'callid',true);
select set_config('test.cid',:'cid',true);
do $$begin
 begin perform public.authorize_call(current_setting('test.callid')::uuid);raise exception 'unaccepted caller media allowed';exception when raise_exception then if sqlerrm='unaccepted caller media allowed' then raise;end if;end;
end$$;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',true);
do $$begin
 begin perform public.authorize_call(current_setting('test.callid')::uuid);raise exception 'outsider token allowed';exception when raise_exception then if sqlerrm='outsider token allowed' then raise;end if;end;
end$$;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',true);
do $$begin
 begin perform public.authorize_call(current_setting('test.callid')::uuid);raise exception 'unanswered callee token allowed';exception when raise_exception then if sqlerrm='unanswered callee token allowed' then raise;end if;end;
end$$;
insert into public.user_blocks(blocker_id,blocked_id) values(auth.uid(),'00000000-0000-0000-0000-000000000001');
do $$begin
 begin perform public.transition_call(current_setting('test.callid')::uuid,'accept');raise exception 'blocked acceptance allowed';exception when raise_exception then if sqlerrm='blocked acceptance allowed' then raise;end if;end;
end$$;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);
do $$begin
 begin perform public.authorize_call(current_setting('test.callid')::uuid);raise exception 'blocked caller token allowed';exception when raise_exception then if sqlerrm='blocked caller token allowed' then raise;end if;end;
end$$;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',true);
delete from public.user_blocks where blocker_id=auth.uid();
select public.transition_call(:'callid','accept');
select public.authorize_call(:'callid');
-- Tokens must not survive either participant leaving, even if the requesting
-- participant still belongs to the conversation.
reset role;
delete from public.conversation_members where conversation_id=:'cid' and user_id='00000000-0000-0000-0000-000000000002';
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);
do $$begin
 begin perform public.authorize_call(current_setting('test.callid')::uuid);raise exception 'removed peer token allowed';exception when raise_exception then if sqlerrm='removed peer token allowed' then raise;end if;end;
end$$;
reset role;
insert into public.conversation_members(conversation_id,user_id) values(:'cid','00000000-0000-0000-0000-000000000002');
update public.calls set created_at=now()-interval '3 hours' where id=:'callid';
set local role authenticated;
do $$begin
 begin perform public.authorize_call(current_setting('test.callid')::uuid);raise exception 'expired token allowed';exception when raise_exception then if sqlerrm='expired token allowed' then raise;end if;end;
end$$;
reset role;
update public.calls set created_at=now() where id=:'callid';
set local role authenticated;
select public.transition_call(:'callid','end');
do $$begin
 begin perform public.authorize_call(current_setting('test.callid')::uuid);raise exception 'ended token allowed';exception when raise_exception then if sqlerrm='ended token allowed' then raise;end if;end;
end$$;
rollback;
\echo 'Call token authorization, blocks, current membership, expiry and terminal state passed.'
