begin;
alter table public.notification_jobs add column lease_until timestamptz;
create function public.claim_notification_jobs() returns setof public.notification_jobs language sql security definer set search_path='' as $$
 update public.notification_jobs j set attempts=j.attempts+1,lease_until=now()+interval '2 minutes'
 where j.id in(select id from public.notification_jobs where sent_at is null and attempts<8 and (lease_until is null or lease_until<now()) order by id for update skip locked limit 50) returning j.*
$$;
revoke all on function public.claim_notification_jobs() from public,anon,authenticated;
grant execute on function public.claim_notification_jobs() to service_role;
commit;
