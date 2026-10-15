begin;
alter table public.calls add column media_closed_at timestamptz;
commit;
