-- Read-only. Run before approval and again immediately before deployment.
begin transaction read only;
select current_database(),to_regclass('supabase_migrations.schema_migrations') as migration_history;
select table_schema,table_name,column_name,data_type from information_schema.columns
where (table_schema='public' and table_name in ('messages','message_attachments','media_validations','groups'))
or (table_schema='private' and table_name in ('chat_upload_deadlines','media_cleanup_jobs')) order by 1,2,ordinal_position;
select n.nspname,p.proname,pg_get_functiondef(p.oid) as definition from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where (n.nspname='storage' and p.proname='allow_only_operation') or (n.nspname='public' and p.proname in ('retention_media_jobs','complete_media_cleanup','claim_view_once'));
select schemaname,tablename,policyname,cmd,qual,with_check from pg_policies where schemaname in ('public','storage') and tablename in ('objects','message_attachments');
select count(*) as visual_objects,count(*) filter(where o.created_at<=now()-interval '48 hours') as expired_objects,
 coalesce(sum((o.metadata->>'size')::bigint) filter(where o.created_at<=now()-interval '48 hours'),0) as expired_bytes,
 count(*) filter(where exists(select 1 from public.groups g where g.avatar_path=o.name)) as persistent_icons
from storage.objects o where bucket_id='chat-media' and (metadata->>'mimetype' like 'image/%' or metadata->>'mimetype' like 'video/%');
select count(*) as attachment_rows,count(*) filter(where o.id is null) as missing_objects,
 count(*) filter(where o.created_at<=now()-interval '48 hours' and not exists(select 1 from public.groups g where g.avatar_path=a.object_path)) as expired_attachment_rows
from public.message_attachments a left join storage.objects o on o.bucket_id='chat-media' and o.name=a.object_path
where a.mime_type like 'image/%' or a.mime_type like 'video/%';
rollback;
