-- =============================================================================
-- 20260806090700_realtime
-- Liveness. Clients subscribe to requests filtered by provider_id (provider
-- queue) or receiver_id (my requests). RLS applies to realtime payloads, so a
-- subscriber only receives rows it is already allowed to read.
--
-- Realtime is a NOTIFICATION, not the source of truth: on any event the client
-- re-reads the authoritative view to get the derived position.
-- =============================================================================

do $$
begin
  if not exists (
    select 1 from pg_publication where pubname = 'supabase_realtime'
  ) then
    create publication supabase_realtime;
  end if;
end
$$;

-- Add requests to the publication (idempotent).
do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'requests'
  ) then
    alter publication supabase_realtime add table public.requests;
  end if;
end
$$;

-- REPLICA IDENTITY FULL so UPDATE payloads carry the old row too. Without it a
-- client cannot tell which row left the queue when only the status changed.
alter table public.requests replica identity full;

-- Item visibility toggles should reach open receiver screens promptly.
do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'items'
  ) then
    alter publication supabase_realtime add table public.items;
  end if;
end
$$;
