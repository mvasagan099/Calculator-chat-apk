grant usage on schema public to public;
-- Test-only minimal Supabase schema contracts for a standalone PostgreSQL 17.
-- This verifies PostgreSQL authorization, not Supabase gateway/provider behavior.
do $$ begin if not exists(select 1 from pg_roles where rolname='anon') then create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls; end if; end $$;
create schema auth;
create schema storage;
create schema realtime;
create schema extensions;
create table auth.users(id uuid primary key,raw_user_meta_data jsonb default '{}');
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
grant usage on schema auth to authenticated,anon,service_role;
grant execute on function auth.uid() to public;
create function auth.jwt() returns jsonb language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb,'{}'::jsonb) $$;
grant execute on function auth.jwt() to public;
create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text references storage.buckets,name text,metadata jsonb,created_at timestamptz default now(),unique(bucket_id,name));
alter table storage.objects enable row level security;
grant usage on schema storage to authenticated;
grant select,insert,delete on storage.objects to authenticated;
create table realtime.messages(id bigint,extension text,topic text);
alter table realtime.messages enable row level security;
grant usage on schema realtime to authenticated;
grant select,insert on realtime.messages to authenticated;
create publication supabase_realtime;
