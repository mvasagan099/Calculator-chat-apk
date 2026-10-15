begin;
-- A call invitation is not a permanent media grant: recheck both participants
-- against current membership and blocks at acceptance and token issuance.
create function private.call_members_allowed(callid uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select count(*)=2
    and bool_and(m.user_id is not null)
    and not exists (
      select 1 from public.call_participants a
      join public.call_participants b on b.call_id=a.call_id and b.user_id<>a.user_id
      where a.call_id=callid and private.blocked(a.user_id,b.user_id)
    )
 from public.calls c join public.call_participants p on p.call_id=c.id
 left join public.conversation_members m on m.conversation_id=c.conversation_id and m.user_id=p.user_id
 where c.id=callid
$$;
create function public.authorize_call(callid uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c public.calls; begin
 select * into c from public.calls where id=callid for share;
 if auth.uid() is null or not exists(select 1 from public.call_participants where call_id=callid and user_id=auth.uid())
    or not private.call_members_allowed(callid) then raise exception 'Call unavailable'; end if;
 if c.state not in ('ringing','accepted') or c.created_at<=now()-interval '2 hours'
    or (c.state='ringing' and (c.caller_id<>auth.uid() or c.created_at<=now()-interval '45 seconds'))
 then raise exception 'Call unavailable'; end if;
 return jsonb_build_object('room_name',c.room_name);
end $$;
create or replace function public.transition_call(callid uuid, action text) returns void language plpgsql security definer set search_path='' as $$
declare c public.calls; newstate text; begin
 select * into c from public.calls where id=callid for update;
 if not exists(select 1 from public.call_participants where call_id=callid and user_id=auth.uid()) then raise exception 'Not a participant'; end if;
 if c.state not in ('ringing','accepted') then return; end if;
 if action='accept' and c.state='ringing' and c.caller_id<>auth.uid() and c.created_at>now()-interval '45 seconds' then
   if not private.call_members_allowed(callid) then raise exception 'Call unavailable'; end if;
   newstate='accepted';
 elsif action='reject' and c.state='ringing' and c.caller_id<>auth.uid() then newstate='rejected';
 elsif action='busy' and c.state='ringing' and c.caller_id<>auth.uid() then newstate='busy';
 elsif action='cancel' and c.state='ringing' and c.caller_id=auth.uid() then newstate='cancelled';
 elsif action='timeout' and c.state='ringing' and c.created_at<=now()-interval '45 seconds' then newstate='missed';
 elsif action='end' then newstate=case when c.state='ringing' then 'cancelled' else 'ended' end;
 elsif action='disconnect' and c.state='accepted' then newstate='disconnected';
 else raise exception 'Invalid transition'; end if;
 update public.calls set state=newstate,answered_at=case when newstate='accepted' then now() else answered_at end,ended_at=case when newstate<>'accepted' then now() end where id=callid;
 if newstate='accepted' then update public.call_participants set joined_at=now() where call_id=callid and user_id=auth.uid();
 else
 update public.call_participants set left_at=now() where call_id=callid;
 insert into public.call_history(call_id,user_id,outcome) select callid,user_id,newstate from public.call_participants where call_id=callid on conflict do nothing;
 end if;
end $$;
revoke all on function private.call_members_allowed(uuid) from public,anon,authenticated;
revoke all on function public.authorize_call(uuid) from public,anon;
grant execute on function public.authorize_call(uuid) to authenticated;
commit;
