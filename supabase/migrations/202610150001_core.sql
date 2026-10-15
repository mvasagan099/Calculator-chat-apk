begin;
create extension if not exists pgcrypto with schema extensions;
create schema if not exists private;
revoke all on schema private from public;

create table public.profiles (
 id uuid primary key references auth.users on delete cascade,
 public_id uuid not null default gen_random_uuid() unique,
 username text not null unique check (username ~ '^[a-z0-9_]{3,30}$'),
 display_name text not null check (length(display_name) between 1 and 80),
 avatar_path text, about text not null default '' check(length(about)<=300),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.user_settings (
 user_id uuid primary key references public.profiles on delete cascade,
 read_receipts boolean not null default true, last_seen_visible boolean not null default true,
 notifications boolean not null default true, status_privacy text not null default 'contacts' check(status_privacy in ('contacts','nobody')),
 last_seen_at timestamptz, updated_at timestamptz not null default now()
);
create table public.contacts (
 owner_id uuid not null references public.profiles on delete cascade,
 contact_id uuid not null references public.profiles on delete cascade,
 created_at timestamptz not null default now(), primary key(owner_id,contact_id), check(owner_id<>contact_id)
);
create table public.user_blocks (
 blocker_id uuid not null references public.profiles on delete cascade,
 blocked_id uuid not null references public.profiles on delete cascade,
 created_at timestamptz not null default now(), primary key(blocker_id,blocked_id), check(blocker_id<>blocked_id)
);
create table public.conversations (
 id uuid primary key default gen_random_uuid(), kind text not null check(kind in ('direct','group')),
 direct_key text unique, created_by uuid references public.profiles on delete set null,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.conversation_members (
 conversation_id uuid not null references public.conversations on delete cascade,
 user_id uuid not null references public.profiles on delete cascade,
 role text not null default 'member' check(role in ('admin','member')),
 joined_at timestamptz not null default now(), last_read_at timestamptz not null default '-infinity',
 pinned boolean not null default false, archived boolean not null default false,
 muted boolean not null default false, primary key(conversation_id,user_id)
);
create table public.groups (
 conversation_id uuid primary key references public.conversations on delete cascade,
 name text not null check(length(name) between 1 and 100), description text not null default '' check(length(description)<=1000),
 avatar_path text, admin_only boolean not null default false, created_at timestamptz not null default now()
);
create table public.group_invitations (
 id uuid primary key default gen_random_uuid(), conversation_id uuid not null references public.groups(conversation_id) on delete cascade,
 invited_by uuid references public.profiles on delete set null, invitee_id uuid not null references public.profiles on delete cascade,
 expires_at timestamptz not null default now()+interval '7 days', accepted_at timestamptz,
 unique(conversation_id,invitee_id)
);
create table public.messages (
 id uuid primary key default gen_random_uuid(), conversation_id uuid not null references public.conversations on delete cascade,
 sender_id uuid references public.profiles on delete set null,
 body text not null default '' check(length(body)<=16000), kind text not null default 'text' check(kind in ('text','image','video','audio','voice','file','contact','location')),
 reply_to uuid references public.messages on delete set null, forwarded boolean not null default false,
 created_at timestamptz not null default now(), edited_at timestamptz, deleted_at timestamptz
);
create index messages_page on public.messages(conversation_id,created_at desc,id desc);
create index messages_search on public.messages using gin(to_tsvector('simple',body));
create table public.message_attachments (
 id uuid primary key default gen_random_uuid(), message_id uuid not null unique references public.messages on delete cascade,
 object_path text not null unique, filename text not null check(length(filename)<=200),
 mime_type text not null, size_bytes bigint not null check(size_bytes between 1 and 26214400),
 created_at timestamptz not null default now()
);
create table public.message_reactions (
 message_id uuid not null references public.messages on delete cascade, user_id uuid not null references public.profiles on delete cascade,
 emoji text not null check(length(emoji) between 1 and 16), created_at timestamptz not null default now(), primary key(message_id,user_id)
);
create table public.message_receipts (
 message_id uuid not null references public.messages on delete cascade, user_id uuid not null references public.profiles on delete cascade,
 delivered_at timestamptz not null default now(), read_at timestamptz, primary key(message_id,user_id)
);
create table public.message_edits (
 id uuid primary key default gen_random_uuid(), message_id uuid not null references public.messages on delete cascade,
 previous_body text not null, edited_at timestamptz not null default now()
);
create table public.message_hides (
 message_id uuid not null references public.messages on delete cascade, user_id uuid not null references public.profiles on delete cascade,
 primary key(message_id,user_id)
);
create table public.calls (
 id uuid primary key default gen_random_uuid(), conversation_id uuid not null references public.conversations on delete cascade,
 caller_id uuid references public.profiles on delete set null, room_name text not null unique default 'call_'||gen_random_uuid()::text,
 video boolean not null default false,
 state text not null default 'ringing' check(state in ('ringing','accepted','rejected','missed','busy','cancelled','ended','disconnected')),
 created_at timestamptz not null default now(), answered_at timestamptz, ended_at timestamptz
);
create table public.call_participants (
 call_id uuid not null references public.calls on delete cascade, user_id uuid not null references public.profiles on delete cascade,
 joined_at timestamptz, left_at timestamptz, primary key(call_id,user_id)
);
create table public.call_history (
 call_id uuid not null references public.calls on delete cascade, user_id uuid not null references public.profiles on delete cascade,
 outcome text not null, created_at timestamptz not null default now(), primary key(call_id,user_id)
);
create table public.status_updates (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles on delete cascade,
 body text not null default '' check(length(body)<=1000), object_path text, kind text not null default 'text' check(kind in ('text','image','video')),
 created_at timestamptz not null default now(), expires_at timestamptz not null default now()+interval '24 hours',
 check(expires_at<=created_at+interval '24 hours')
);
create table public.status_views (
 status_id uuid not null references public.status_updates on delete cascade, user_id uuid not null references public.profiles on delete cascade,
 viewed_at timestamptz not null default now(), primary key(status_id,user_id)
);
create table public.status_mutes (
 owner_id uuid not null references public.profiles on delete cascade, user_id uuid not null references public.profiles on delete cascade,
 primary key(owner_id,user_id)
);
create table public.push_tokens (
 user_id uuid not null references public.profiles on delete cascade, token text not null check(length(token) between 16 and 4096),
 updated_at timestamptz not null default now(), primary key(user_id,token)
);
create table public.user_reports (
 id uuid primary key default gen_random_uuid(), reporter_id uuid not null references public.profiles on delete cascade,
 reported_id uuid references public.profiles on delete set null, reason text not null check(length(reason) between 10 and 2000),
 created_at timestamptz not null default now()
);
create table public.notification_jobs (
 id bigint generated always as identity primary key, recipient_id uuid not null references public.profiles on delete cascade,
 kind text not null, resource_id uuid not null, created_at timestamptz not null default now(), sent_at timestamptz,
 attempts integer not null default 0, unique(recipient_id,kind,resource_id)
);
create table private.rate_limits (user_id uuid not null, operation text not null, bucket timestamptz not null, count integer not null, primary key(user_id,operation,bucket));
create index members_by_user on public.conversation_members(user_id,conversation_id);
create index calls_pending on public.calls(created_at) where state in ('ringing','accepted');
create index statuses_expiry on public.status_updates(expires_at);
create index notifications_pending on public.notification_jobs(created_at) where sent_at is null;

create function private.is_member(cid uuid, uid uuid default auth.uid()) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.conversation_members where conversation_id=cid and user_id=uid)
$$;
create function private.is_admin(cid uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.conversation_members where conversation_id=cid and user_id=auth.uid() and role='admin')
$$;
create function private.blocked(a uuid,b uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.user_blocks where (blocker_id=a and blocked_id=b) or (blocker_id=b and blocked_id=a))
$$;
create function private.message_member(mid uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.messages m where m.id=mid and private.is_member(m.conversation_id))
$$;
create function private.can_status(sid uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.status_updates s where s.id=sid and (s.user_id=auth.uid() or
 (s.expires_at>now() and not private.blocked(s.user_id,auth.uid()) and exists(select 1 from public.contacts c where c.owner_id=s.user_id and c.contact_id=auth.uid())
 and exists(select 1 from public.user_settings u where u.user_id=s.user_id and u.status_privacy='contacts'))))
$$;
grant usage on schema private to authenticated;
grant execute on function private.is_member(uuid,uuid), private.is_admin(uuid), private.blocked(uuid,uuid), private.message_member(uuid), private.can_status(uuid) to authenticated;

-- Authenticated clients can read only rows their policies authorize. All
-- high impact mutations go through bounded, validated definer functions.
do $$ declare t text; begin
 foreach t in array array['profiles','user_settings','contacts','user_blocks','conversations','conversation_members','groups','group_invitations','messages','message_attachments','message_reactions','message_receipts','message_edits','message_hides','calls','call_participants','call_history','status_updates','status_views','status_mutes','push_tokens','user_reports','notification_jobs'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('revoke all on public.%I from anon, authenticated',t);
 execute format('grant select on public.%I to authenticated',t);
 execute format('grant all on public.%I to service_role',t);
 end loop;
end $$;
grant usage,select on sequence public.notification_jobs_id_seq to service_role;
create policy profiles_read on public.profiles for select to authenticated using(true);
grant update(username,display_name,avatar_path,about,updated_at) on public.profiles to authenticated;
create policy profiles_update on public.profiles for update to authenticated using(id=auth.uid()) with check(id=auth.uid());
create policy settings_owner on public.user_settings for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
grant update(read_receipts,last_seen_visible,notifications,status_privacy,last_seen_at,updated_at) on public.user_settings to authenticated;
create policy contacts_owner on public.contacts for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
grant insert,delete on public.contacts to authenticated;
create policy blocks_owner on public.user_blocks for all to authenticated using(blocker_id=auth.uid()) with check(blocker_id=auth.uid());
grant insert,delete on public.user_blocks to authenticated;
create policy conversations_member on public.conversations for select to authenticated using(private.is_member(id));
create policy members_read on public.conversation_members for select to authenticated using(private.is_member(conversation_id));
grant update(pinned,archived,muted) on public.conversation_members to authenticated;
create policy members_preferences on public.conversation_members for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
create policy groups_member on public.groups for select to authenticated using(private.is_member(conversation_id));
create policy invitations_read on public.group_invitations for select to authenticated using(invitee_id=auth.uid() or private.is_admin(conversation_id));
create policy messages_member on public.messages for select to authenticated using(private.is_member(conversation_id));
create policy attachments_member on public.message_attachments for select to authenticated using(private.message_member(message_id));
create policy reactions_member on public.message_reactions for select to authenticated using(private.message_member(message_id));
create policy receipts_member on public.message_receipts for select to authenticated using(private.message_member(message_id));
create policy edits_owner on public.message_edits for select to authenticated using(exists(select 1 from public.messages m where m.id=message_id and m.sender_id=auth.uid()));
create policy hides_owner on public.message_hides for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid() and private.message_member(message_id));
grant insert,delete on public.message_hides to authenticated;
create policy calls_member on public.calls for select to authenticated using(exists(select 1 from public.call_participants p where p.call_id=id and p.user_id=auth.uid()));
create policy participants_read on public.call_participants for select to authenticated using(user_id=auth.uid());
create policy history_owner on public.call_history for select to authenticated using(user_id=auth.uid());
create policy statuses_view on public.status_updates for select to authenticated using(private.can_status(id));
create policy status_views_read on public.status_views for select to authenticated using(user_id=auth.uid() or exists(select 1 from public.status_updates s where s.id=status_id and s.user_id=auth.uid()));
create policy status_mutes_owner on public.status_mutes for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
grant insert,delete on public.status_mutes to authenticated;
create policy tokens_owner on public.push_tokens for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
grant insert,update,delete on public.push_tokens to authenticated;
create policy reports_owner on public.user_reports for all to authenticated using(reporter_id=auth.uid()) with check(reporter_id=auth.uid());
grant insert on public.user_reports to authenticated;
-- notification_jobs deliberately has no client policy.

create function private.new_user() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.profiles(id,username,display_name) values(new.id,'u_'||left(md5(new.id::text),26),left(coalesce(nullif(new.raw_user_meta_data->>'display_name',''),'New user'),80));
 insert into public.user_settings(user_id) values(new.id); return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function private.new_user();

create function private.limit_operation(op text, max_count integer) returns void language plpgsql security definer set search_path='' as $$
declare n integer; begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 insert into private.rate_limits values(auth.uid(),op,date_trunc('minute',now()),1)
 on conflict(user_id,operation,bucket) do update set count=private.rate_limits.count+1 returning count into n;
 if n>max_count then raise exception 'Rate limit exceeded' using errcode='P0001'; end if;
end $$;

create function public.create_direct(peer uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare cid uuid; k text; begin
 perform private.limit_operation('create_direct',20);
 if peer=auth.uid() or private.blocked(peer,auth.uid()) then raise exception 'Unavailable'; end if;
 if not exists(select 1 from public.profiles where id=peer) then raise exception 'User not found'; end if;
 k=least(peer::text,auth.uid()::text)||':'||greatest(peer::text,auth.uid()::text);
 insert into public.conversations(kind,direct_key,created_by) values('direct',k,auth.uid())
 on conflict(direct_key) do update set direct_key=excluded.direct_key returning id into cid;
 insert into public.conversation_members(conversation_id,user_id) values(cid,auth.uid()),(cid,peer) on conflict do nothing;
 return cid;
end $$;

create function public.send_message(cid uuid, mid uuid, content text, message_kind text default 'text', reply uuid default null, is_forwarded boolean default false, attachment jsonb default null) returns uuid language plpgsql security definer set search_path='' as $$
declare existing public.messages; path text; begin
 perform private.limit_operation('send',60);
 if not private.is_member(cid) then raise exception 'Not a member'; end if;
 if exists(select 1 from public.conversation_members m where m.conversation_id=cid and private.blocked(m.user_id,auth.uid())) then raise exception 'Interaction blocked'; end if;
 if exists(select 1 from public.groups where conversation_id=cid and admin_only) and not private.is_admin(cid) then raise exception 'Admins only'; end if;
 select * into existing from public.messages where id=mid;
 if found then
  if existing.sender_id<>auth.uid() or existing.conversation_id<>cid then raise exception 'Conflicting message ID'; end if;
  return mid;
 end if;
 if reply is not null and not exists(select 1 from public.messages where id=reply and conversation_id=cid) then raise exception 'Invalid reply'; end if;
 if length(trim(content))=0 and attachment is null then raise exception 'Empty message'; end if;
 if message_kind in ('image','video','audio','voice','file') and attachment is null then raise exception 'Attachment required'; end if;
 insert into public.messages(id,conversation_id,sender_id,body,kind,reply_to,forwarded) values(mid,cid,auth.uid(),content,message_kind,reply,is_forwarded);
 if attachment is not null then
  path=attachment->>'object_path';
  if path not like cid::text||'/'||auth.uid()::text||'/%' then raise exception 'Invalid object owner'; end if;
  if not exists(select 1 from storage.objects where bucket_id='chat-media' and name=path and (metadata->>'size')::bigint between 1 and 26214400) then raise exception 'Missing or invalid object'; end if;
  insert into public.message_attachments(message_id,object_path,filename,mime_type,size_bytes)
  select mid,path,left(attachment->>'filename',200),metadata->>'mimetype',(metadata->>'size')::bigint from storage.objects where bucket_id='chat-media' and name=path;
 end if;
 update public.conversations set updated_at=now() where id=cid;
 insert into public.notification_jobs(recipient_id,kind,resource_id)
 select m.user_id,'message',mid from public.conversation_members m join public.user_settings s on s.user_id=m.user_id
 where m.conversation_id=cid and m.user_id<>auth.uid() and not m.muted and s.notifications on conflict do nothing;
 return mid;
end $$;

create function public.edit_message(mid uuid, content text) returns void language plpgsql security definer set search_path='' as $$
declare m public.messages; begin
 perform private.limit_operation('edit',30);
 select * into m from public.messages where id=mid for update;
 if m.sender_id is distinct from auth.uid() or not private.is_member(m.conversation_id) or m.deleted_at is not null or m.created_at<now()-interval '15 minutes' or m.kind<>'text' or length(trim(content))=0 then raise exception 'Edit not permitted'; end if;
 insert into public.message_edits(message_id,previous_body) values(mid,m.body);
 update public.messages set body=content,edited_at=now() where id=mid;
end $$;
create function public.delete_message(mid uuid) returns void language plpgsql security definer set search_path='' as $$
declare m public.messages; begin
 select * into m from public.messages where id=mid for update;
 if not private.is_member(m.conversation_id) or not ((m.sender_id=auth.uid() and m.created_at>now()-interval '24 hours') or private.is_admin(m.conversation_id)) then raise exception 'Delete not permitted'; end if;
 update public.messages set body='',deleted_at=now() where id=mid;
 delete from public.message_edits where message_id=mid;
 delete from public.message_reactions where message_id=mid;
end $$;
create function public.ack_messages(cid uuid, mark_read boolean default false) returns void language plpgsql security definer set search_path='' as $$
begin
 if not private.is_member(cid) then raise exception 'Not a member'; end if;
 insert into public.message_receipts(message_id,user_id,read_at)
 select m.id,auth.uid(),case when mark_read and (select read_receipts from public.user_settings where user_id=auth.uid()) then now() end
 from public.messages m where m.conversation_id=cid and m.sender_id<>auth.uid() and m.created_at>now()-interval '30 days'
 on conflict(message_id,user_id) do update set read_at=coalesce(public.message_receipts.read_at,excluded.read_at);
 if mark_read then update public.conversation_members set last_read_at=now() where conversation_id=cid and user_id=auth.uid(); end if;
end $$;
create function public.react_message(mid uuid, reaction text) returns void language plpgsql security definer set search_path='' as $$
begin
 perform private.limit_operation('reaction',60);
 if not private.message_member(mid) or exists(select 1 from public.messages where id=mid and deleted_at is not null) then raise exception 'Not permitted'; end if;
 if reaction is null then delete from public.message_reactions where message_id=mid and user_id=auth.uid();
 else insert into public.message_reactions(message_id,user_id,emoji) values(mid,auth.uid(),reaction) on conflict(message_id,user_id) do update set emoji=excluded.emoji; end if;
end $$;

create function public.conversation_list() returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(row_to_json(x) order by x.pinned desc,x.updated_at desc),'[]'::jsonb) from (
 select c.id,c.kind,c.updated_at,m.pinned,m.archived,m.muted,
 coalesce(g.name,p.display_name,'Deleted account') as title,coalesce(g.avatar_path,p.avatar_path) as avatar_path,p.id as peer_id,
 (select body from public.messages mm where mm.conversation_id=c.id and mm.deleted_at is null and not exists(select 1 from public.message_hides h where h.message_id=mm.id and h.user_id=auth.uid()) order by created_at desc,id desc limit 1) as preview,
 (select count(*) from public.messages mm where mm.conversation_id=c.id and mm.created_at>m.last_read_at and mm.sender_id<>auth.uid() and mm.deleted_at is null) as unread
 from public.conversations c join public.conversation_members m on m.conversation_id=c.id and m.user_id=auth.uid()
 left join public.groups g on g.conversation_id=c.id
 left join public.conversation_members other on other.conversation_id=c.id and other.user_id<>auth.uid() and c.kind='direct'
 left join public.profiles p on p.id=other.user_id
 )x
$$;

-- Delete authenticated accounts only via an Edge Function that reauthenticates.
-- Realtime uses the same RLS select rules as HTTP queries.
alter publication supabase_realtime add table public.messages, public.conversations, public.conversation_members, public.message_receipts, public.message_reactions, public.calls, public.group_invitations, public.status_updates;
create policy private_conversation_events on realtime.messages for select to authenticated using (
 extension in ('broadcast','presence') and topic ~ '^conversation:[0-9a-f-]{36}$' and private.is_member(split_part(topic,':',2)::uuid)
);
create policy private_conversation_send on realtime.messages for insert to authenticated with check (
 extension in ('broadcast','presence') and topic ~ '^conversation:[0-9a-f-]{36}$' and private.is_member(split_part(topic,':',2)::uuid)
);

-- Revoke default PUBLIC execution before selectively exposing RPCs.
revoke execute on all functions in schema private from public,anon;
do $$ declare f record; begin
 for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('create_direct','send_message','edit_message','delete_message','ack_messages','react_message','conversation_list') loop
 execute format('revoke all on function %s from public,anon',f.signature);
 execute format('grant execute on function %s to authenticated',f.signature);
 end loop;
end $$;
commit;
