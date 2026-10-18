begin;
-- Add account_devices to realtime publication so approved devices receive
-- instant notifications when a session is approved, revoked, or updated.
alter publication supabase_realtime add table public.account_devices;

-- Add an index on account_devices for quick lookup by user and session
create index if not exists account_devices_user_session_idx
  on public.account_devices (user_id, session_id);

-- Ensure rename_account_device RPC is available for users to name their devices
create or replace function public.rename_account_device(target uuid, new_name text)
returns void language plpgsql security definer set search_path='' as $$
begin
  perform private.require_session();
  if length(trim(new_name)) not between 1 and 80 then
    raise exception 'Device name must be between 1 and 80 characters';
  end if;
  update public.account_devices
  set name = trim(new_name)
  where id = target and user_id = auth.uid() and revoked_at is null;
  if not found then
    raise exception 'Device not found or not active';
  end if;
end $$;

revoke all on function public.rename_account_device(uuid, text) from public, anon;
grant execute on function public.rename_account_device(uuid, text) to authenticated;

commit;
