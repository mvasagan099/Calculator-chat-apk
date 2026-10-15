begin;
create table public.message_mentions(message_id uuid not null references public.messages on delete cascade,user_id uuid not null references public.profiles on delete cascade,primary key(message_id,user_id));
alter table public.message_mentions enable row level security;
revoke all on public.message_mentions from anon,authenticated;
grant select on public.message_mentions to authenticated;
create policy mentions_member on public.message_mentions for select to authenticated using(private.message_member(message_id));
create function private.capture_mentions() returns trigger language plpgsql security definer set search_path='' as $$
begin
 delete from public.message_mentions where message_id=new.id;
 insert into public.message_mentions(message_id,user_id)
 select distinct new.id,p.id from regexp_matches(new.body,'(^|[[:space:]])@([a-z0-9_]{3,30})','g') as match
 join public.profiles p on p.username=match[2]
 join public.conversation_members m on m.user_id=p.id and m.conversation_id=new.conversation_id
 on conflict do nothing;
 return new;
end $$;
create trigger message_mentions_capture after insert or update of body on public.messages for each row execute function private.capture_mentions();
create function private.limit_metadata() returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform private.limit_operation(TG_TABLE_NAME,case when TG_TABLE_NAME='user_reports' then 3 when TG_TABLE_NAME='push_tokens' then 15 else 60 end);
 return new;
end $$;
create trigger reports_rate_limit before insert on public.user_reports for each row execute function private.limit_metadata();
create trigger contacts_rate_limit before insert on public.contacts for each row execute function private.limit_metadata();
create trigger tokens_rate_limit before insert on public.push_tokens for each row execute function private.limit_metadata();
revoke execute on all functions in schema private from public,anon;
commit;
