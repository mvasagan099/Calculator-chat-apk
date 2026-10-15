-- Run AFTER deployment. Store backend-only secrets through Supabase Vault.
-- Create named Vault secrets `calculator_worker_url` (your maintenance URL),
-- `calculator_push_url` (your dispatch-push URL), and `calculator_worker_secret`.
-- Their values must match the Edge Function project and MAINTENANCE_SECRET.
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;
select cron.schedule('calculator-maintenance','* * * * *',$job$
 select net.http_post(url:=(select decrypted_secret from vault.decrypted_secrets where name='calculator_worker_url'),
 headers:=jsonb_build_object('Content-Type','application/json','x-worker-secret',(select decrypted_secret from vault.decrypted_secrets where name='calculator_worker_secret')),body:='{}'::jsonb);
$job$);
-- pg_cron supports second intervals on current Supabase. Message/call push
-- jobs are dispatched every 5 seconds, independently of the sender app.
select cron.schedule('calculator-push','5 seconds',$job$
 select net.http_post(url:=(select decrypted_secret from vault.decrypted_secrets where name='calculator_push_url'),
 headers:=jsonb_build_object('Content-Type','application/json','x-worker-secret',(select decrypted_secret from vault.decrypted_secrets where name='calculator_worker_secret')),body:='{}'::jsonb);
$job$);
