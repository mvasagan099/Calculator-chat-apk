\set ON_ERROR_STOP on
begin;
insert into auth.users(id) values('40000000-0000-0000-0000-000000000001'),('40000000-0000-0000-0000-000000000002'),('40000000-0000-0000-0000-000000000003');
set local role authenticated;
select set_config('request.jwt.claim.sub','40000000-0000-0000-0000-000000000001',true);
insert into public.contacts(owner_id,contact_id) values(auth.uid(),'40000000-0000-0000-0000-000000000002');
select public.create_status('Visible to my contact') as sid \gset
select set_config('test.sid',:'sid',true);
select set_config('request.jwt.claim.sub','40000000-0000-0000-0000-000000000003',true);
do $$begin if exists(select 1 from public.status_updates)then raise exception 'status leaked to non-contact';end if;end$$;
select set_config('request.jwt.claim.sub','40000000-0000-0000-0000-000000000002',true);
do $$begin if not exists(select 1 from public.status_updates)then raise exception 'contact status missing';end if;end$$;
select public.view_status(:'sid');
insert into public.user_blocks(blocker_id,blocked_id) values(auth.uid(),'40000000-0000-0000-0000-000000000001');
do $$begin if exists(select 1 from public.status_updates)then raise exception 'blocked status visible';end if;end$$;
reset role;
update public.status_updates set created_at=now()-interval '25 hours',expires_at=now()-interval '1 hour' where id=:'sid';
set local role authenticated;
select set_config('request.jwt.claim.sub','40000000-0000-0000-0000-000000000002',true);
delete from public.user_blocks where blocker_id=auth.uid();
do $$begin if exists(select 1 from public.status_updates)then raise exception 'expired status visible';end if;end$$;
rollback;
\echo 'Contact-scoped status privacy, view tracking, blocking and expiry passed.'
