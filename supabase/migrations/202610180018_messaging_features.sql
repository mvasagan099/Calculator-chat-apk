begin;

-- 1. Extend message kinds to support polls, stickers, and GIFs
alter table public.messages drop constraint if exists messages_kind_check;
alter table public.messages add constraint messages_kind_check check (
  kind in ('text','image','video','audio','voice','file','contact','location','poll','sticker','gif')
);

-- 2. Starred / Saved Messages Table
create table if not exists public.starred_messages (
  user_id uuid references auth.users(id) on delete cascade not null,
  message_id uuid references public.messages(id) on delete cascade not null,
  conversation_id uuid references public.conversations(id) on delete cascade not null,
  created_at timestamptz default now() not null,
  primary key (user_id, message_id)
);

create index if not exists idx_starred_user_conv on public.starred_messages(user_id, conversation_id);

alter table public.starred_messages enable row level security;
drop policy if exists starred_owner on public.starred_messages;
create policy starred_owner on public.starred_messages
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Star / Unstar RPCs
create or replace function public.star_message(mid uuid, cid uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
  perform private.require_session();
  if not private.is_member(cid) then
    raise exception 'Not a conversation member';
  end if;
  if not exists (select 1 from public.messages where id = mid and conversation_id = cid and deleted_at is null) then
    raise exception 'Message not found';
  end if;
  insert into public.starred_messages(user_id, message_id, conversation_id)
  values (auth.uid(), mid, cid)
  on conflict do nothing;
end $$;

create or replace function public.unstar_message(mid uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
  perform private.require_session();
  delete from public.starred_messages where user_id = auth.uid() and message_id = mid;
end $$;

-- 3. Scheduled Messages Table
create table if not exists public.scheduled_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid references public.conversations(id) on delete cascade not null,
  sender_id uuid references auth.users(id) on delete cascade not null,
  body text not null default '' check(length(body) <= 16000),
  kind text not null default 'text' check(kind in ('text','image','video','audio','voice','file','contact','location','poll','sticker','gif')),
  scheduled_for timestamptz not null,
  created_at timestamptz default now() not null
);

create index if not exists idx_scheduled_sender on public.scheduled_messages(sender_id, scheduled_for);

alter table public.scheduled_messages enable row level security;
drop policy if exists scheduled_owner on public.scheduled_messages;
create policy scheduled_owner on public.scheduled_messages
  for all using (auth.uid() = sender_id) with check (auth.uid() = sender_id);

-- 4. Group Poll Voting RPC
create or replace function public.vote_poll(mid uuid, option_index int) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  target_msg public.messages;
  poll_data jsonb;
  votes_obj jsonb;
  user_votes jsonb;
  is_multiple boolean;
  uid_str text;
  updated_body text;
begin
  perform private.require_session();
  select * into target_msg from public.messages where id = mid and deleted_at is null;
  if not found or target_msg.kind <> 'poll' then
    raise exception 'Poll message not found';
  end if;
  if not private.is_member(target_msg.conversation_id) then
    raise exception 'Not a conversation member';
  end if;

  poll_data := target_msg.body::jsonb;
  is_multiple := coalesce((poll_data->>'multiple')::boolean, false);
  votes_obj := coalesce(poll_data->'votes', '{}'::jsonb);
  uid_str := auth.uid()::text;
  user_votes := coalesce(votes_obj->uid_str, '[]'::jsonb);

  if is_multiple then
    -- Toggle vote for this option
    if user_votes @> jsonb_build_array(option_index) then
      user_votes := (select coalesce(jsonb_agg(elem), '[]'::jsonb) from jsonb_array_elements(user_votes) elem where elem::int <> option_index);
    else
      user_votes := user_votes || jsonb_build_array(option_index);
    end if;
  else
    -- Single-choice: if already selected, deselect; otherwise replace
    if user_votes @> jsonb_build_array(option_index) then
      user_votes := '[]'::jsonb;
    else
      user_votes := jsonb_build_array(option_index);
    end if;
  end if;

  votes_obj := jsonb_set(votes_obj, array[uid_str], user_votes);
  poll_data := jsonb_set(poll_data, array['votes'], votes_obj);
  updated_body := poll_data::text;

  update public.messages set body = updated_body, edited_at = now() where id = mid;
  return poll_data;
end $$;

-- 5. Realtime Publication
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin
      alter publication supabase_realtime add table public.starred_messages;
    exception when duplicate_object then
      null;
    end;
    begin
      alter publication supabase_realtime add table public.scheduled_messages;
    exception when duplicate_object then
      null;
    end;
  end if;
end $$;

-- Permissions
revoke all on function public.star_message(uuid, uuid), public.unstar_message(uuid), public.vote_poll(uuid, int) from public, anon;
grant execute on function public.star_message(uuid, uuid), public.unstar_message(uuid), public.vote_poll(uuid, int) to authenticated;

commit;
