\set ON_ERROR_STOP on
begin;
insert into auth.users(id) values('60000000-0000-0000-0000-000000000001'),('60000000-0000-0000-0000-000000000002'),('60000000-0000-0000-0000-000000000003'),('60000000-0000-0000-0000-000000000004'),('60000000-0000-0000-0000-000000000005');
set local role authenticated;
select set_config('request.jwt.claim.sub','60000000-0000-0000-0000-000000000001',true);
select set_config('request.jwt.claims','{"session_id":"61000000-0000-0000-0000-000000000001"}',true);
select public.create_group('Call test') as cid \gset
reset role;
insert into public.conversation_members(conversation_id,user_id) values(:'cid','60000000-0000-0000-0000-000000000002'),(:'cid','60000000-0000-0000-0000-000000000003'),(:'cid','60000000-0000-0000-0000-000000000004');
set local role authenticated;
select public.begin_call(:'cid',true,'62000000-0000-0000-0000-000000000001') as callid \gset
select set_config('test.call',:'callid',true);
select set_config('test.cid',:'cid',true);
reset role;
select set_config('request.jwt.claims','{"session_id":"61000000-0000-0000-0000-000000000002"}',true);
insert into public.push_tokens(user_id,token) values('60000000-0000-0000-0000-000000000002','test-call-registration-one');
select set_config('request.jwt.claims','{"session_id":"61000000-0000-0000-0000-000000000099"}',true);
insert into public.push_tokens(user_id,token) values('60000000-0000-0000-0000-000000000002','test-call-registration-two');
do $$begin if (select count(*) from public.call_notification_tokens(current_setting('test.call')::uuid,'60000000-0000-0000-0000-000000000002'))<>1 then raise exception 'Multi-device ringing enabled';end if;end$$;
set local role authenticated;
select set_config('request.jwt.claims','{"session_id":"61000000-0000-0000-0000-000000000001"}',true);
do $$begin
 if public.begin_call(current_setting('test.cid')::uuid,true,'62000000-0000-0000-0000-000000000001')<>current_setting('test.call')::uuid then raise exception 'duplicate call';end if;
 begin perform public.authorize_call(current_setting('test.call')::uuid);raise exception 'ringing media token';exception when raise_exception then if sqlerrm='ringing media token' then raise;end if;end;
end$$;
select set_config('request.jwt.claim.sub','60000000-0000-0000-0000-000000000002',true);
select set_config('request.jwt.claims','{"session_id":"61000000-0000-0000-0000-000000000002"}',true);
select public.transition_call(:'callid','accept');
select public.transition_call(:'callid','accept');
select public.authorize_call(:'callid');
do $$begin
 if (select count(*) from public.call_participants where call_id=current_setting('test.call')::uuid)<>4 then raise exception 'participant roster denied';end if;
 begin perform public.remove_call_participant(current_setting('test.call')::uuid,'60000000-0000-0000-0000-000000000003');raise exception 'nonadmin removal';exception when raise_exception then if sqlerrm='nonadmin removal' then raise;end if;end;
end$$;
select set_config('request.jwt.claims','{"session_id":"61000000-0000-0000-0000-000000000099"}',true);
do $$begin
 begin perform public.authorize_call(current_setting('test.call')::uuid);raise exception 'second session media';exception when raise_exception then if sqlerrm='second session media' then raise;end if;end;
 begin perform public.transition_call(current_setting('test.call')::uuid,'accept');raise exception 'second session duplicate join';exception when raise_exception then if sqlerrm='second session duplicate join' then raise;end if;end;
end$$;
select set_config('request.jwt.claim.sub','60000000-0000-0000-0000-000000000003',true);
do $$begin
 begin perform public.authorize_call(current_setting('test.call')::uuid);raise exception 'unaccepted group media';exception when raise_exception then if sqlerrm='unaccepted group media' then raise;end if;end;
end$$;
select public.transition_call(:'callid','accept');
select set_config('request.jwt.claim.sub','60000000-0000-0000-0000-000000000004',true);
select public.transition_call(:'callid','reject');
do $$begin if (select state from public.calls where id=current_setting('test.call')::uuid)<>'accepted' then raise exception 'decline ended group';end if;end$$;
select set_config('request.jwt.claim.sub','60000000-0000-0000-0000-000000000005',true);
select public.create_direct('60000000-0000-0000-0000-000000000002') as waiting_cid \gset
select public.begin_call(:'waiting_cid',false,'62000000-0000-0000-0000-000000000002') as waiting \gset
select set_config('test.waiting',:'waiting',true);
select set_config('request.jwt.claim.sub','60000000-0000-0000-0000-000000000002',true);
select set_config('request.jwt.claims','{"session_id":"61000000-0000-0000-0000-000000000002"}',true);
do $$begin
 begin perform public.transition_call(current_setting('test.waiting')::uuid,'accept');raise exception 'busy double join';exception when raise_exception then if sqlerrm='busy double join' then raise;end if;end;
end$$;
select public.transition_call(:'waiting','busy');
select set_config('request.jwt.claim.sub','60000000-0000-0000-0000-000000000001',true);
select set_config('request.jwt.claims','{"session_id":"61000000-0000-0000-0000-000000000001"}',true);
select public.remove_call_participant(:'callid','60000000-0000-0000-0000-000000000003');
select public.invite_call_participant(:'callid','60000000-0000-0000-0000-000000000004');
do $$begin
 begin perform public.invite_call_participant(current_setting('test.call')::uuid,'60000000-0000-0000-0000-000000000005');raise exception 'outsider invitation';exception when raise_exception then if sqlerrm='outsider invitation' then raise;end if;end;
end$$;
select public.transition_call(:'callid','leave');
select public.transition_call(:'callid','join');
select public.authorize_call(:'callid');
reset role;
do $$begin
 if not exists(select 1 from private.call_eviction_jobs j join public.call_participants p on p.call_id=j.call_id and p.user_id=j.user_id where j.call_id=current_setting('test.call')::uuid and j.identity<>p.user_id::text||':'||p.media_epoch::text) then raise exception 'rejoin eviction epoch not isolated';end if;
end$$;
update public.call_participants set invitation_expires_at=now()-interval '1 second' where call_id=:'callid' and user_id='60000000-0000-0000-0000-000000000004';
set local role authenticated;
select set_config('request.jwt.claim.sub','60000000-0000-0000-0000-000000000004',true);
do $$begin
 begin perform public.transition_call(current_setting('test.call')::uuid,'accept');raise exception 'expired invitation';exception when raise_exception then if sqlerrm='expired invitation' then raise;end if;end;
end$$;
select set_config('request.jwt.claim.sub','60000000-0000-0000-0000-000000000003',true);
do $$begin
 begin perform public.authorize_call(current_setting('test.call')::uuid);raise exception 'removed media';exception when raise_exception then if sqlerrm='removed media' then raise;end if;end;
 begin perform public.transition_call(current_setting('test.call')::uuid,'join');raise exception 'removed rejoin';exception when raise_exception then if sqlerrm='removed rejoin' then raise;end if;end;
end$$;
reset role;
delete from public.conversation_members where conversation_id=:'cid' and user_id='60000000-0000-0000-0000-000000000002';
select public.reconcile_calls();
do $$begin if exists(select 1 from public.call_participants where call_id=current_setting('test.call')::uuid and user_id='60000000-0000-0000-0000-000000000002' and state='joined') then raise exception 'removed group member remains joined';end if;end$$;
select room_name as testroom from public.calls where id=:'callid' \gset
select user_id::text||':'||media_epoch::text as media_identity from public.call_participants where call_id=:'callid' and user_id='60000000-0000-0000-0000-000000000001' \gset
select public.record_call_media(:'testroom',:'media_identity',false,extract(epoch from now())::bigint);
select public.reconcile_calls();
do $$begin if not exists(select 1 from public.call_participants where call_id=current_setting('test.call')::uuid and user_id='60000000-0000-0000-0000-000000000001' and state='joined') then raise exception 'no reconnect grace';end if;end$$;
select public.record_call_media(:'testroom',:'media_identity',true,extract(epoch from now())::bigint+1);
select public.record_call_media(:'testroom',:'media_identity',false,extract(epoch from now())::bigint-1);
do $$begin if exists(select 1 from public.call_participants where call_id=current_setting('test.call')::uuid and user_id='60000000-0000-0000-0000-000000000001' and media_disconnected_at is not null) then raise exception 'old webhook overwrote reconnection';end if;end$$;
set local role authenticated;
select set_config('request.jwt.claim.sub','60000000-0000-0000-0000-000000000001',true);
select public.transition_call(:'callid','end_for_all');
select public.transition_call(:'callid','accept');
do $$begin if (select state from public.calls where id=current_setting('test.call')::uuid)<>'ended' then raise exception 'late action revived call';end if;end$$;
select public.begin_call(:'cid',true,'62000000-0000-0000-0000-000000000003') as stale_call \gset
select set_config('test.stale',:'stale_call',true);
select set_config('request.jwt.claim.sub','60000000-0000-0000-0000-000000000003',true);
select public.transition_call(:'stale_call','accept');
reset role;
select room_name as stale_room from public.calls where id=:'stale_call' \gset
select user_id::text||':'||media_epoch::text as stale_identity from public.call_participants where call_id=:'stale_call' and user_id='60000000-0000-0000-0000-000000000001' \gset
select public.record_call_media(:'stale_room',:'stale_identity',false,extract(epoch from now())::bigint);
update public.call_participants set media_disconnected_at=now()-interval '91 seconds' where call_id=:'stale_call' and user_id='60000000-0000-0000-0000-000000000001';
select public.reconcile_calls();
do $$begin
 if not exists(select 1 from public.call_participants where call_id=current_setting('test.stale')::uuid and user_id='60000000-0000-0000-0000-000000000001' and state='removed') then raise exception 'stale media retained';end if;
 if not exists(select 1 from public.call_participants where call_id=current_setting('test.stale')::uuid and user_id='60000000-0000-0000-0000-000000000003' and state='joined') then raise exception 'stale media cleanup removed group peer';end if;
end$$;
rollback;
\echo 'Advanced call idempotency, four-member authorization, waiting/busy, session isolation, expiry, removal, epoch-safe rejoin and terminal races passed.'
