begin;
alter table public.calls add column group_call boolean not null default false;
alter table public.calls add column request_id uuid;
alter table public.calls add column updated_at timestamptz not null default now();
create unique index calls_request on public.calls(caller_id,request_id) where request_id is not null;
alter table public.call_participants add column state text not null default 'invited' check(state in ('invited','joined','declined','left','removed','missed','busy'));
alter table public.call_participants add column invited_at timestamptz not null default now();
alter table public.call_participants add column invitation_expires_at timestamptz not null default now()+interval '45 seconds';
alter table public.call_participants add column accepted_session uuid;
alter table public.call_participants add column media_epoch uuid not null default gen_random_uuid();
alter table public.call_participants add column media_disconnected_at timestamptz;
alter table public.call_participants add column media_event_at bigint not null default 0;
update public.call_participants p set state=case when c.state='accepted' then 'joined' when c.state<>'ringing' then 'left' when p.user_id=c.caller_id then 'joined' else 'invited' end from public.calls c where c.id=p.call_id;
create index participant_active on public.call_participants(user_id,state,call_id);
create index call_invitation_expiry on public.call_participants(invitation_expires_at) where state='invited';
create index call_media_departure on public.call_participants(media_disconnected_at) where state='joined' and media_disconnected_at is not null;
create table private.call_eviction_jobs(call_id uuid not null references public.calls on delete cascade,user_id uuid not null,identity text not null,created_at timestamptz not null default now(),primary key(call_id,identity));
create function private.call_visible(callid uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.call_participants p join public.calls c on c.id=p.call_id where p.call_id=callid and p.user_id=auth.uid() and (c.state not in ('ringing','accepted') or private.is_member(c.conversation_id)))
$$;
drop policy participants_read on public.call_participants;
create policy participants_read on public.call_participants for select to authenticated using(private.call_visible(call_id));
create function private.call_eligible(callid uuid, person uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.calls c join public.conversation_members m on m.conversation_id=c.conversation_id where c.id=callid and m.user_id=person)
 and not exists(select 1 from public.call_participants p where p.call_id=callid and p.state in ('joined','invited') and p.user_id<>person and private.blocked(p.user_id,person))
$$;
create function private.call_busy(person uuid, except_call uuid default null) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.calls c join public.call_participants p on p.call_id=c.id where p.user_id=person and p.state='joined' and c.id is distinct from except_call and c.state in ('ringing','accepted') and c.created_at>now()-interval '2 hours')
$$;
create function private.call_terminal() returns trigger language plpgsql security definer set search_path='' as $$
begin
 new.updated_at=clock_timestamp();
 if new.state not in ('ringing','accepted') and old.state in ('ringing','accepted') then
  new.ended_at=coalesce(new.ended_at,now());
  update public.call_participants set state=case when state='invited' then 'missed' when state='joined' then 'left' else state end,left_at=coalesce(left_at,now()) where call_id=new.id;
  insert into public.call_history(call_id,user_id,outcome) select new.id,user_id,new.state from public.call_participants where call_id=new.id on conflict do nothing;
 end if;
 return new;
end $$;
create trigger call_terminal before update on public.calls for each row execute function private.call_terminal();

create function public.begin_call(cid uuid,use_video boolean,request uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare callid uuid; is_group boolean;begin
 perform private.require_session();
 perform pg_advisory_xact_lock(hashtextextended('calculator_calls',0));
 if request is null then raise exception 'Request identity required';end if;
 select id into callid from public.calls where caller_id=auth.uid() and request_id=request;
 if found then
  if not exists(select 1 from public.calls where id=callid and conversation_id=cid and video=use_video) then raise exception 'Request conflict';end if;
  return callid;
 end if;
 perform private.limit_operation('call',5);
 if not private.is_member(cid) then raise exception 'Conversation unavailable';end if;
 select kind='group' into is_group from public.conversations where id=cid;
 if (select count(*) from public.conversation_members where conversation_id=cid)<2 then raise exception 'At least two members required';end if;
 if private.call_busy(auth.uid()) then raise exception 'End your current call first';end if;
 if not is_group and (select count(*) from public.conversation_members where conversation_id=cid)<>2 then raise exception 'Two participants required';end if;
 if exists(select 1 from public.conversation_members where conversation_id=cid and private.blocked(user_id,auth.uid())) then raise exception 'Call unavailable';end if;
 -- Only one live group room per conversation; rejoin it rather than split it.
 if is_group and exists(select 1 from public.calls where conversation_id=cid and state in ('ringing','accepted') and created_at>now()-interval '2 hours') then raise exception 'An active group call already exists';end if;
 insert into public.calls(conversation_id,caller_id,video,group_call,request_id) values(cid,auth.uid(),use_video,is_group,request) returning id into callid;
 insert into public.call_participants(call_id,user_id,state,joined_at,accepted_session)
 select callid,user_id,case when user_id=auth.uid() then 'joined' else 'invited' end,case when user_id=auth.uid() then now() end,case when user_id=auth.uid() then private.jwt_session() end from public.conversation_members where conversation_id=cid;
 insert into public.notification_jobs(recipient_id,kind,resource_id) select p.user_id,'call',callid from public.call_participants p join public.user_settings s using(user_id) where p.call_id=callid and p.user_id<>auth.uid() and s.notifications;
 return callid;
end $$;
create or replace function public.start_call(cid uuid,use_video boolean default false) returns uuid language plpgsql security definer set search_path='' as $$
begin return public.begin_call(cid,use_video,gen_random_uuid());end $$;

create or replace function public.transition_call(callid uuid,action text) returns void language plpgsql security definer set search_path='' as $$
declare c public.calls;p public.call_participants; terminal text;begin
 perform private.require_session();
 perform pg_advisory_xact_lock(hashtextextended('calculator_calls',0));
 select * into c from public.calls where id=callid for update;
 select * into p from public.call_participants where call_id=callid and user_id=auth.uid() for update;
 if p.user_id is null then raise exception 'Not a participant';end if;
 if c.state not in ('ringing','accepted') then return;end if;
 if action in ('accept','join') then
  if p.state='joined' then
   if p.accepted_session is distinct from private.jwt_session() and p.accepted_session is not null then raise exception 'Already joined on another session';end if;
   return;
  end if;
  if not private.call_eligible(callid,auth.uid()) or p.state not in ('invited','left') or (p.state='invited' and p.invitation_expires_at<=now()) or (p.state='left' and (not c.group_call or c.state<>'accepted')) or c.created_at<=now()-interval '2 hours' then raise exception 'Invitation unavailable';end if;
  if not c.group_call and not private.call_members_allowed(callid) then raise exception 'Call unavailable';end if;
  if private.call_busy(auth.uid(),callid) then raise exception 'End the current call before answering';end if;
  update public.call_participants set state='joined',joined_at=coalesce(joined_at,now()),left_at=null,accepted_session=private.jwt_session(),media_epoch=gen_random_uuid(),media_disconnected_at=null,media_event_at=0 where call_id=callid and user_id=auth.uid();
  update public.calls set state='accepted',answered_at=coalesce(answered_at,now()) where id=callid;
  return;
 elsif action in ('reject','busy') then
  if p.state in ('declined','busy','missed') then return;end if;
  if p.state<>'invited' then raise exception 'Not an invitation';end if;
  update public.call_participants set state=case when action='busy' then 'busy' else 'declined' end,left_at=now() where call_id=callid and user_id=auth.uid();
  insert into public.call_history(call_id,user_id,outcome) values(callid,auth.uid(),case when action='busy' then 'busy' else 'rejected' end) on conflict do nothing;
  if not c.group_call then terminal=case when action='busy' then 'busy' else 'rejected' end;end if;
 elsif action='timeout' then
  if c.state<>'ringing' or c.created_at>now()-interval '45 seconds' then raise exception 'Not expired';end if;
  terminal='missed';
 elsif action in ('end','cancel','disconnect','leave') then
  if action='cancel' and c.caller_id<>auth.uid() then raise exception 'Caller required';end if;
  if p.accepted_session is not null and p.accepted_session is distinct from private.jwt_session() then raise exception 'Different active session';end if;
  if c.group_call then
   if action='cancel' and c.caller_id<>auth.uid() then raise exception 'Caller required';end if;
   if p.state='left' then return;end if;
   if p.state<>'joined' then raise exception 'Join before leaving';end if;
   update public.call_participants set state='left',left_at=now() where call_id=callid and user_id=auth.uid();
   insert into private.call_eviction_jobs(call_id,user_id,identity) values(callid,auth.uid(),auth.uid()::text||':'||p.media_epoch::text) on conflict do nothing;
   insert into public.call_history(call_id,user_id,outcome) values(callid,auth.uid(),'left') on conflict do nothing;
   if not exists(select 1 from public.call_participants where call_id=callid and state='joined') then terminal=case when c.state='ringing' then 'cancelled' else 'ended' end;end if;
  else
   terminal=case when action='disconnect' and c.state='accepted' then 'disconnected' when c.state='ringing' then 'cancelled' else 'ended' end;
  end if;
 elsif action='end_for_all' then
  if not c.group_call or (c.caller_id<>auth.uid() and not private.is_admin(c.conversation_id)) then raise exception 'Host or admin required';end if;
  terminal=case when c.state='ringing' then 'cancelled' else 'ended' end;
 else raise exception 'Invalid transition';end if;
 if terminal is not null then update public.calls set state=terminal,ended_at=now() where id=callid;
 else update public.calls set updated_at=clock_timestamp() where id=callid;end if;
end $$;

create or replace function public.authorize_call(callid uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.calls;p public.call_participants;begin
 perform private.require_session();
 select * into c from public.calls where id=callid for share;
 select * into p from public.call_participants where call_id=callid and user_id=auth.uid();
 if p.state is distinct from 'joined' or (p.accepted_session is not null and p.accepted_session is distinct from private.jwt_session()) or not private.call_eligible(callid,auth.uid()) or (not c.group_call and not private.call_members_allowed(callid)) or c.state<>'accepted' or c.created_at<=now()-interval '2 hours' then raise exception 'Call unavailable';end if;
 perform private.limit_operation('call_token',20);
 return jsonb_build_object('room_name',c.room_name,'video',c.video,'identity',auth.uid()::text||':'||p.media_epoch::text);
end $$;
create function public.call_snapshot(callid uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.calls;begin
 perform private.require_session();
 if not private.call_visible(callid) then raise exception 'Call unavailable';end if;
 select * into c from public.calls where id=callid;
 return to_jsonb(c)||jsonb_build_object('invitation_expires_at',(select invitation_expires_at from public.call_participants where call_id=callid and user_id=auth.uid()),'self_state',(select state from public.call_participants where call_id=callid and user_id=auth.uid()),'participants',(select jsonb_agg(jsonb_build_object('user_id',p.user_id,'state',p.state,'joined_at',p.joined_at,'left_at',p.left_at,'display_name',f.display_name)) from public.call_participants p join public.profiles f on f.id=p.user_id where p.call_id=callid));
end $$;
create function public.invite_call_participant(callid uuid,person uuid) returns void language plpgsql security definer set search_path='' as $$
declare c public.calls;begin
 perform private.require_session();perform private.limit_operation('call_invite',10);
 perform pg_advisory_xact_lock(hashtextextended('calculator_calls',0));
 select * into c from public.calls where id=callid for update;
 if not c.group_call or c.state<>'accepted' or not exists(select 1 from public.call_participants where call_id=callid and user_id=auth.uid() and state='joined' and (accepted_session is null or accepted_session=private.jwt_session())) or not private.call_eligible(callid,auth.uid()) or not private.call_eligible(callid,person) then raise exception 'Invitation unavailable';end if;
 if exists(select 1 from public.call_participants where call_id=callid and user_id=person and state in ('joined','removed')) then raise exception 'Participant unavailable';end if;
 insert into public.call_participants(call_id,user_id) values(callid,person) on conflict(call_id,user_id) do update set state='invited',invited_at=now(),invitation_expires_at=now()+interval '45 seconds',left_at=null;
 delete from public.notification_jobs where kind='call' and resource_id=callid and recipient_id=person;
 insert into public.notification_jobs(recipient_id,kind,resource_id) select person,'call',callid from public.user_settings where user_id=person and notifications;
 update public.calls set updated_at=clock_timestamp() where id=callid;
end $$;
create function public.remove_call_participant(callid uuid,person uuid) returns void language plpgsql security definer set search_path='' as $$
declare c public.calls;begin
 perform private.require_session();
 perform pg_advisory_xact_lock(hashtextextended('calculator_calls',0));
 select * into c from public.calls where id=callid for update;
 if not c.group_call or c.state not in ('ringing','accepted') or not private.is_member(c.conversation_id) or (c.caller_id<>auth.uid() and not private.is_admin(c.conversation_id)) or person=auth.uid() then raise exception 'Removal unavailable';end if;
 update public.call_participants set state='removed',left_at=now() where call_id=callid and user_id=person;
 insert into private.call_eviction_jobs(call_id,user_id,identity) select callid,person,person::text||':'||media_epoch::text from public.call_participants where call_id=callid and user_id=person on conflict do nothing;
 update public.calls set updated_at=clock_timestamp() where id=callid;
end $$;
-- Only signed LiveKit webhooks may report media departure. Keep a reconnect
-- grace period; a matching newer join clears departure before reconciliation.
create function public.record_call_media(roomname text,participant_identity text,connected boolean,event_seconds bigint) returns void language plpgsql security definer set search_path='' as $$
declare callid uuid;begin
 perform pg_advisory_xact_lock(hashtextextended('calculator_calls',0));
 if event_seconds<=0 or event_seconds>extract(epoch from now())::bigint+300 then raise exception 'Invalid event time';end if;
 select id into callid from public.calls where room_name=roomname and state='accepted';
 if callid is null then return;end if;
 update public.call_participants set media_disconnected_at=case when connected then null else now() end,media_event_at=event_seconds
 where call_id=callid and state='joined' and user_id::text||':'||media_epoch::text=participant_identity and (event_seconds>media_event_at or (event_seconds=media_event_at and connected));
 if found then update public.calls set updated_at=clock_timestamp() where id=callid;end if;
end $$;
revoke all on function public.record_call_media(text,text,boolean,bigint) from public,anon,authenticated;
grant execute on function public.record_call_media(text,text,boolean,bigint) to service_role;
create function public.reconcile_calls() returns void language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(hashtextextended('calculator_calls',0));
 insert into private.call_eviction_jobs(call_id,user_id,identity) select p.call_id,p.user_id,p.user_id::text||':'||p.media_epoch::text from public.call_participants p join public.calls c on c.id=p.call_id where c.state in ('ringing','accepted') and p.state='joined' and (not private.call_eligible(p.call_id,p.user_id) or not private.session_allowed_for(p.user_id,p.accepted_session) or p.media_disconnected_at<=now()-interval '90 seconds') on conflict do nothing;
 update public.call_participants p set state='removed',left_at=now() from private.call_eviction_jobs j where p.call_id=j.call_id and p.user_id=j.user_id and j.identity=p.user_id::text||':'||p.media_epoch::text and p.state='joined';
 update public.call_participants set state='missed',left_at=now() where state='invited' and invitation_expires_at<=now();
 update public.calls c set state=case when c.state='ringing' then 'missed' else 'ended' end where c.state in ('ringing','accepted') and (not exists(select 1 from public.call_participants p where p.call_id=c.id and p.state='joined') or (not c.group_call and c.state='accepted' and (select count(*) from public.call_participants p where p.call_id=c.id and p.state='joined')<>2));
 update public.calls set updated_at=clock_timestamp() where state in ('ringing','accepted');
end $$;
create function public.call_evictions() returns table(call_id uuid,identity text,room_name text) language sql security definer set search_path='' as $$select j.call_id,j.identity,c.room_name from private.call_eviction_jobs j join public.calls c on c.id=j.call_id order by j.created_at limit 100$$;
create function public.complete_call_eviction(callid uuid,participant_identity text) returns void language sql security definer set search_path='' as $$delete from private.call_eviction_jobs where call_id=callid and identity=participant_identity$$;
-- Multi-device ringing is deliberately disabled pending Phase 4 hosted/device
-- verification. Choose one currently authorized registration per invitation.
create function public.call_notification_tokens(callid uuid,recipient uuid) returns table(token text) language sql stable security definer set search_path='' as $$
 select t.token from public.push_tokens t where t.user_id=recipient and t.session_id is not null and private.session_allowed_for(recipient,t.session_id)
 and exists(select 1 from public.calls c join public.call_participants p on p.call_id=c.id where c.id=callid and c.state in ('ringing','accepted') and p.user_id=recipient and p.state='invited' and p.invitation_expires_at>now() and private.call_eligible(callid,recipient))
 order by t.updated_at desc,t.token limit 1
$$;
revoke all on function public.call_notification_tokens(uuid,uuid) from public,anon,authenticated;
grant execute on function public.call_notification_tokens(uuid,uuid) to service_role;
revoke all on function public.begin_call(uuid,boolean,uuid),public.call_snapshot(uuid),public.invite_call_participant(uuid,uuid),public.remove_call_participant(uuid,uuid) from public,anon;
grant execute on function public.begin_call(uuid,boolean,uuid),public.call_snapshot(uuid),public.invite_call_participant(uuid,uuid),public.remove_call_participant(uuid,uuid) to authenticated;
revoke all on function public.reconcile_calls(),public.call_evictions(),public.complete_call_eviction(uuid,text) from public,anon,authenticated;
grant execute on function public.reconcile_calls(),public.call_evictions(),public.complete_call_eviction(uuid,text) to service_role;
revoke all on function private.call_visible(uuid),private.call_eligible(uuid,uuid),private.call_busy(uuid,uuid),private.call_terminal() from public,anon,authenticated;
grant execute on function private.call_visible(uuid) to authenticated;
commit;
