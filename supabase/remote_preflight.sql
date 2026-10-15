-- Read-only inspection AFTER the owner confirms the target project URL/ref in
-- the Supabase dashboard and CLI. Does not apply migrations or print user data.
begin transaction read only;
select current_database() as database_name, current_user as database_role;
select to_regclass('supabase_migrations.schema_migrations') is not null as migration_history_exists;
select table_schema,table_name from information_schema.tables
where table_schema in ('public','storage','supabase_migrations') order by 1,2;
select n.nspname as schema_name,c.relname as table_name,c.relrowsecurity as rls_enabled
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname in ('public','storage') and c.relkind='r' order by 1,2;
select schemaname,tablename,policyname,roles,cmd,qual,with_check
from pg_policies where schemaname in ('public','storage','realtime') order by 1,2,3;
select table_schema,table_name,grantee,privilege_type
from information_schema.role_table_grants where grantee in ('anon','authenticated')
and table_schema in ('public','storage') order by 1,2,3,4;
select n.nspname,p.proname,p.prosecdef,p.proconfig,
 has_function_privilege('anon',p.oid,'EXECUTE') as anon_execute
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname in ('public','private') order by 1,2;
select pubname,schemaname,tablename from pg_publication_tables
where pubname='supabase_realtime' order by 2,3;
select id,public,file_size_limit,allowed_mime_types from storage.buckets
where id in ('chat-media','avatars','status-media');
select extname,extversion from pg_extension where extname in ('pgcrypto','pg_cron','pg_net','supabase_vault');
rollback;
