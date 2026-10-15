begin;
create function public.create_group(title text, description text default '') returns uuid language plpgsql security definer set search_path='' as $$
declare cid uuid; begin
 perform private.limit_operation('group_create',5);
 insert into public.conversations(kind,created_by) values('group',auth.uid()) returning id into cid;
 insert into public.conversation_members(conversation_id,user_id,role) values(cid,auth.uid(),'admin');
 insert into public.groups(conversation_id,name,description) values(cid,title,description);
 return cid;
end $$;
create function public.manage_group(cid uuid, action text, target uuid default null, value text default null) returns void language plpgsql security definer set search_path='' as $$
declare r text; begin
 perform private.limit_operation('group_manage',30);
 perform 1 from public.conversations where id=cid and kind='group' for update;
 if not found then raise exception 'Group not found'; end if;
 select role into r from public.conversation_members where conversation_id=cid and user_id=auth.uid();
 if r is null then raise exception 'Not a member'; end if;
 if action='leave' then
  if r='admin' and not exists(select 1 from public.conversation_members where conversation_id=cid and user_id<>auth.uid() and role='admin') then raise exception 'Promote another admin or delete the group first'; end if;
  delete from public.conversation_members where conversation_id=cid and user_id=auth.uid(); return;
 end if;
 if r<>'admin' then raise exception 'Admin required'; end if;
 case action
 when 'invite' then
  if private.blocked(target,auth.uid()) then raise exception 'Unavailable'; end if;
  insert into public.group_invitations(conversation_id,invited_by,invitee_id) values(cid,auth.uid(),target)
  on conflict(conversation_id,invitee_id) do update set expires_at=now()+interval '7 days',accepted_at=null,invited_by=auth.uid();
 when 'remove' then
  if target=auth.uid() then raise exception 'Use leave'; end if;
  delete from public.conversation_members where conversation_id=cid and user_id=target;
 when 'promote' then update public.conversation_members set role='admin' where conversation_id=cid and user_id=target;
 when 'name' then update public.groups set name=value where conversation_id=cid;
 when 'description' then update public.groups set description=value where conversation_id=cid;
 when 'avatar' then
  if value not like cid::text||'/'||auth.uid()::text||'/%' or not exists(select 1 from public.media_validations where bucket='chat-media' and object_path=value and user_id=auth.uid()) then raise exception 'Invalid object path'; end if;
  update public.groups set avatar_path=value where conversation_id=cid;
 when 'admin_only' then update public.groups set admin_only=value::boolean where conversation_id=cid;
 when 'delete' then delete from public.conversations where id=cid;
 else raise exception 'Unknown operation'; end case;
end $$;
create function public.accept_invitation(iid uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare i public.group_invitations; begin
 select * into i from public.group_invitations where id=iid for update;
 if not found or i.invitee_id<>auth.uid() or i.expires_at<=now() or i.accepted_at is not null or private.blocked(i.invited_by,auth.uid()) then raise exception 'Invitation unavailable'; end if;
 insert into public.conversation_members(conversation_id,user_id) values(i.conversation_id,auth.uid()) on conflict do nothing;
 update public.group_invitations set accepted_at=now() where id=iid;
 return i.conversation_id;
end $$;
create function public.start_call(cid uuid, use_video boolean default false) returns uuid language plpgsql security definer set search_path='' as $$
declare callid uuid; begin
 perform private.limit_operation('call',5);
 -- Serialize overlapping calls so two callers cannot reserve the same user.
 perform pg_advisory_xact_lock(hashtextextended('calculator_calls',0));
 if not private.is_member(cid) or not exists(select 1 from public.conversations where id=cid and kind='direct') then raise exception 'Direct conversation required'; end if;
 if (select count(*) from public.conversation_members where conversation_id=cid)<>2 then raise exception 'Two participants required'; end if;
 if exists(select 1 from public.conversation_members where conversation_id=cid and private.blocked(user_id,auth.uid())) then raise exception 'Unavailable'; end if;
 if exists(select 1 from public.calls c join public.call_participants p on p.call_id=c.id join public.conversation_members m on m.user_id=p.user_id and m.conversation_id=cid where c.state in ('ringing','accepted') and c.created_at>now()-interval '2 hours') then raise exception 'Participant is busy'; end if;
 insert into public.calls(conversation_id,caller_id,video) values(cid,auth.uid(),use_video) returning id into callid;
 insert into public.call_participants(call_id,user_id) select callid,user_id from public.conversation_members where conversation_id=cid;
 insert into public.notification_jobs(recipient_id,kind,resource_id)
 select user_id,'call',callid from public.conversation_members m join public.user_settings s using(user_id) where conversation_id=cid and user_id<>auth.uid() and s.notifications;
 return callid;
end $$;
create function public.transition_call(callid uuid, action text) returns void language plpgsql security definer set search_path='' as $$
declare c public.calls; newstate text; begin
 select * into c from public.calls where id=callid for update;
 if not exists(select 1 from public.call_participants where call_id=callid and user_id=auth.uid()) then raise exception 'Not a participant'; end if;
 if c.state not in ('ringing','accepted') then return; end if;
 if action='accept' and c.state='ringing' and c.caller_id<>auth.uid() and c.created_at>now()-interval '45 seconds' then newstate='accepted';
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
create function public.create_status(content text, media_path text default null, media_kind text default 'text') returns uuid language plpgsql security definer set search_path='' as $$
declare sid uuid; begin
 perform private.limit_operation('status',10);
 if length(trim(content))=0 and media_path is null then raise exception 'Empty status'; end if;
 if media_kind<>'text' and media_path is null then raise exception 'Media required'; end if;
 if media_path is not null and (media_path not like auth.uid()::text||'/%' or not exists(select 1 from storage.objects where bucket_id='status-media' and name=media_path)) then raise exception 'Invalid media'; end if;
 insert into public.status_updates(user_id,body,object_path,kind) values(auth.uid(),content,media_path,media_kind) returning id into sid; return sid;
end $$;
create function public.view_status(sid uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if not private.can_status(sid) then raise exception 'Status unavailable'; end if;
 if exists(select 1 from public.status_updates where id=sid and user_id=auth.uid()) then return;end if;
 insert into public.status_views(status_id,user_id) values(sid,auth.uid()) on conflict do nothing;
end $$;
create function public.delete_status(sid uuid) returns void language plpgsql security definer set search_path='' as $$
begin delete from public.status_updates where id=sid and user_id=auth.uid(); end $$;
create function public.peer_presence(peer uuid) returns timestamptz language sql stable security definer set search_path='' as $$
 select last_seen_at from public.user_settings where user_id=peer and last_seen_visible and not private.blocked(peer,auth.uid())
 and exists(select 1 from public.conversation_members a join public.conversation_members b using(conversation_id) where a.user_id=auth.uid() and b.user_id=peer)
$$;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values
 ('chat-media','chat-media',false,26214400,array['image/jpeg','image/png','image/webp','video/mp4','audio/mp4','audio/mpeg','audio/aac','audio/ogg','application/pdf','text/plain','application/zip','text/vcard']),
 ('avatars','avatars',false,5242880,array['image/jpeg','image/png','image/webp']),
 ('status-media','status-media',false,26214400,array['image/jpeg','image/png','image/webp','video/mp4'])
on conflict(id) do nothing;
create function private.valid_uuid(s text) returns uuid language plpgsql immutable set search_path='' as $$
begin return s::uuid; exception when invalid_text_representation then return null; end $$;
grant execute on function private.valid_uuid(text) to authenticated;
create policy chat_media_read on storage.objects for select to authenticated using(bucket_id='chat-media' and private.is_member(private.valid_uuid(split_part(name,'/',1))) and (split_part(name,'/',2)=auth.uid()::text or exists(select 1 from public.messages m join public.message_attachments a on a.message_id=m.id where a.object_path=name and m.deleted_at is null) or exists(select 1 from public.groups g where g.avatar_path=storage.objects.name)));
create policy chat_media_write on storage.objects for insert to authenticated with check(bucket_id='chat-media' and private.is_member(private.valid_uuid(split_part(name,'/',1))) and split_part(name,'/',2)=auth.uid()::text and not exists(select 1 from public.conversation_members m where m.conversation_id=private.valid_uuid(split_part(name,'/',1)) and private.blocked(m.user_id,auth.uid())));
create policy chat_media_delete on storage.objects for delete to authenticated using(bucket_id='chat-media' and split_part(name,'/',2)=auth.uid()::text and private.is_member(private.valid_uuid(split_part(name,'/',1))) and not exists(select 1 from public.message_attachments a join public.messages m on m.id=a.message_id where a.object_path=storage.objects.name and m.deleted_at is null) and not exists(select 1 from public.groups g where g.avatar_path=storage.objects.name));
create policy avatars_read on storage.objects for select to authenticated using(bucket_id='avatars' and (split_part(name,'/',1)=auth.uid()::text or exists(select 1 from public.profiles p where p.avatar_path=name)));
create policy avatars_write on storage.objects for insert to authenticated with check(bucket_id='avatars' and split_part(name,'/',1)=auth.uid()::text);
create policy avatars_delete on storage.objects for delete to authenticated using(bucket_id='avatars' and split_part(name,'/',1)=auth.uid()::text);
create policy status_media_read on storage.objects for select to authenticated using(bucket_id='status-media' and (split_part(name,'/',1)=auth.uid()::text or exists(select 1 from public.status_updates s where s.object_path=name and private.can_status(s.id))));
create policy status_media_write on storage.objects for insert to authenticated with check(bucket_id='status-media' and split_part(name,'/',1)=auth.uid()::text);
create policy status_media_delete on storage.objects for delete to authenticated using(bucket_id='status-media' and split_part(name,'/',1)=auth.uid()::text);

-- SQL cleanup handles durable metadata; the maintenance Edge Function deletes
-- expired/orphaned storage objects through the Storage API before metadata.
create function public.maintenance() returns void language plpgsql security definer set search_path='' as $$
begin
 with expired as (update public.calls set state='missed',ended_at=now() where state='ringing' and created_at<now()-interval '45 seconds' returning id)
 insert into public.call_history(call_id,user_id,outcome) select e.id,p.user_id,'missed' from expired e join public.call_participants p on p.call_id=e.id on conflict do nothing;
 insert into public.notification_jobs(recipient_id,kind,resource_id)
 select h.user_id,'missed_call',h.call_id from public.call_history h join public.calls c on c.id=h.call_id where h.outcome='missed' and h.user_id<>c.caller_id on conflict do nothing;
 update public.calls set state='disconnected',ended_at=now() where state='accepted' and created_at<now()-interval '2 hours';
 delete from public.group_invitations where expires_at<now()-interval '7 days';
 delete from public.notification_jobs where created_at<now()-interval '7 days';
 delete from private.rate_limits where bucket<now()-interval '1 day';
 delete from public.push_tokens where updated_at<now()-interval '90 days';
 delete from public.message_edits where edited_at<now()-interval '30 days';
end $$;
revoke all on function public.maintenance() from public,anon,authenticated;
grant execute on function public.maintenance() to service_role;

do $$ declare f record; begin
 for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('create_group','manage_group','accept_invitation','start_call','transition_call','create_status','view_status','delete_status','peer_presence') loop
 execute format('revoke all on function %s from public,anon',f.signature);
 execute format('grant execute on function %s to authenticated',f.signature);
 end loop;
end $$;
revoke execute on all functions in schema private from public,anon;
commit;
