-- =============================================================================
-- 20260806091000_advisor_hardening
--
-- Resolves the Supabase database advisor findings, and materially shrinks the
-- privileged surface of this schema.
--
-- WHAT CHANGED AND WHY
--
-- 1. The four views were SECURITY DEFINER. That worked, but the WHERE
--    predicate inside each view was then the ONLY thing standing between one
--    provider and another's data. Delete a line by accident and isolation is
--    gone silently. They are now security_invoker, so base-table RLS applies
--    as well - the predicate becomes defence in depth rather than the whole
--    defence.
--
-- 2. Cross-tenancy helpers now live in a `private` schema that is NOT exposed
--    through PostgREST (see config.toml: schemas = ["public", "graphql_public"]).
--    They must be SECURITY DEFINER to do their job, but because the schema is
--    unexposed they are unreachable at /rest/v1/rpc/ and raise no advisory.
--
-- 3. Those same helpers break an RLS recursion cycle. A policy on `providers`
--    that reads `requests`, whose policy reads `providers`, is infinite
--    recursion - Postgres raises 42P17 at query time. Definer helpers read
--    their table without re-entering RLS, cutting the cycle. They are also
--    faster: the predicate is evaluated once per row instead of dragging a
--    whole policy chain behind it.
--
-- 4. Every RPC that does not need definer rights is now SECURITY INVOKER.
--    Only the five request-lifecycle functions remain definer, because those
--    are the only ones that must write to `requests`, which clients hold no
--    write grant on. Definer functions in `public`: 14 -> 5.
--
-- 5. Trigger functions are no longer callable over the REST API, and the last
--    function without a pinned search_path has one.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. The private schema: definer predicates, unreachable from the API
-- -----------------------------------------------------------------------------
create schema if not exists private;

revoke all on schema private from public;
grant usage on schema private to anon, authenticated;

-- Does the caller own this provider? Reads providers WITHOUT re-entering RLS.
create or replace function private.is_provider_owner(p_provider_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.providers p
    where p.id = p_provider_id
      and p.owner_id = auth.uid()
  );
$$;

-- Does the caller have any request with this provider? Lets a receiver keep
-- seeing a provider that has since closed, without which their own request
-- history would silently vanish from their screen.
create or replace function private.has_request_with_provider(p_provider_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.requests r
    where r.provider_id = p_provider_id
      and r.receiver_id = auth.uid()
  );
$$;

-- Is this profile someone who is, or has been, in one of the caller's queues?
-- This is exactly what provider_queue and provider_archive display. Stating it
-- as a rule beats letting it fall out of definer rights as a side effect.
create or replace function private.is_queue_counterparty(p_profile_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.requests r
    join public.providers p on p.id = r.provider_id
    where r.receiver_id = p_profile_id
      and p.owner_id = auth.uid()
  );
$$;

-- A receiver must see how many people are ahead of them, which means counting
-- rows they cannot read. Returns one integer, and only to the two entitled
-- parties.
create or replace function private.request_position(p_request_id uuid)
returns integer
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case
           when r.status in ('queued', 'in_progress') then (
             select count(*)::int
             from public.requests r2
             where r2.provider_id = r.provider_id
               and r2.status in ('queued', 'in_progress')
               and r2.seq <= r.seq
           )
         end
  from public.requests r
  where r.id = p_request_id
    and (
      r.receiver_id = auth.uid()
      or exists (
        select 1 from public.providers p
        where p.id = r.provider_id
          and p.owner_id = auth.uid()
      )
    );
$$;

-- Discovery shows "3 waiting". Guests cannot read requests at all, so the count
-- comes from here. Limited to ACTIVE providers - the ones already listed
-- publicly - and returns a number, never an identity.
create or replace function private.provider_queue_length(p_provider_id uuid)
returns integer
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select count(*)::int
  from public.requests r
  join public.providers p on p.id = r.provider_id
  where r.provider_id = p_provider_id
    and p.is_active = true
    and r.status in ('queued', 'in_progress');
$$;

grant execute on function private.is_provider_owner(uuid)        to authenticated;
grant execute on function private.has_request_with_provider(uuid) to authenticated;
grant execute on function private.is_queue_counterparty(uuid)     to authenticated;
grant execute on function private.request_position(uuid)          to authenticated;
grant execute on function private.provider_queue_length(uuid)     to anon, authenticated;


-- -----------------------------------------------------------------------------
-- 2. Rewrite the cross-table policies to use the helpers.
--    Same rules as before; no recursion, and one function call per row.
-- -----------------------------------------------------------------------------

drop policy if exists requests_provider_read on public.requests;
create policy requests_provider_read on public.requests
  for select to authenticated
  using (private.is_provider_owner(provider_id));

drop policy if exists providers_requester_read on public.providers;
create policy providers_requester_read on public.providers
  for select to authenticated
  using (private.has_request_with_provider(id));

drop policy if exists profiles_counterparty_read on public.profiles;
create policy profiles_counterparty_read on public.profiles
  for select to authenticated
  using (private.is_queue_counterparty(id));

drop policy if exists request_items_read on public.request_items;
create policy request_items_read on public.request_items
  for select to authenticated
  using (
    exists (
      select 1
      from public.requests r
      where r.id = request_items.request_id
        and (
          r.receiver_id = auth.uid()
          or private.is_provider_owner(r.provider_id)
        )
    )
  );


-- -----------------------------------------------------------------------------
-- 3. Recreate the views with invoker rights.
--    Predicates are KEPT. They are no longer the only line of defence, but a
--    view that filters correctly on its own is still the right thing to write.
-- -----------------------------------------------------------------------------

drop view if exists public.provider_queue;
drop view if exists public.provider_archive;
drop view if exists public.my_requests;
drop view if exists public.provider_public;

create view public.provider_queue
with (security_invoker = true) as
select
  r.id,
  r.provider_id,
  r.receiver_id,
  r.status,
  r.seq,
  r.note,
  r.created_at,
  r.started_at,
  coalesce(p.display_name, 'Deleted user') as receiver_name,
  p.avatar_url                             as receiver_avatar_url,
  row_number() over (partition by r.provider_id order by r.seq) as position,
  now() - r.created_at                     as wait_time,
  coalesce(li.items, '[]'::jsonb)          as items
from public.requests r
join public.providers pv
  on pv.id = r.provider_id
left join public.profiles p
  on p.id = r.receiver_id
left join lateral (
  select jsonb_agg(
           jsonb_build_object(
             'item_id',  ri.item_id,
             'name',     ri.item_name_snapshot,
             'price',    ri.item_price_snapshot,
             'quantity', ri.quantity
           ) order by ri.item_name_snapshot
         ) as items
  from public.request_items ri
  where ri.request_id = r.id
) li on true
where r.status in ('queued', 'in_progress')
  and pv.owner_id = auth.uid();

comment on view public.provider_queue is
  'Active requests for providers owned by the caller. Invoker rights: base-table RLS applies too.';

create view public.provider_archive
with (security_invoker = true) as
select
  r.id,
  r.provider_id,
  r.receiver_id,
  r.status,
  r.seq,
  r.note,
  r.created_at,
  r.started_at,
  r.completed_at,
  r.cancelled_at,
  coalesce(r.completed_at, r.cancelled_at) as archived_at,
  coalesce(p.display_name, 'Deleted user') as receiver_name,
  coalesce(li.items, '[]'::jsonb)          as items
from public.requests r
join public.providers pv
  on pv.id = r.provider_id
left join public.profiles p
  on p.id = r.receiver_id
left join lateral (
  select jsonb_agg(
           jsonb_build_object(
             'item_id',  ri.item_id,
             'name',     ri.item_name_snapshot,
             'price',    ri.item_price_snapshot,
             'quantity', ri.quantity
           ) order by ri.item_name_snapshot
         ) as items
  from public.request_items ri
  where ri.request_id = r.id
) li on true
where r.status in ('completed', 'cancelled')
  and pv.owner_id = auth.uid();

create view public.my_requests
with (security_invoker = true) as
select
  r.id,
  r.provider_id,
  pv.name        as provider_name,
  pv.cover_url   as provider_cover_url,
  r.status,
  r.note,
  r.created_at,
  r.started_at,
  r.completed_at,
  r.cancelled_at,
  private.request_position(r.id) as position,
  coalesce(li.items, '[]'::jsonb) as items
from public.requests r
join public.providers pv
  on pv.id = r.provider_id
left join lateral (
  select jsonb_agg(
           jsonb_build_object(
             'item_id',  ri.item_id,
             'name',     ri.item_name_snapshot,
             'price',    ri.item_price_snapshot,
             'quantity', ri.quantity
           ) order by ri.item_name_snapshot
         ) as items
  from public.request_items ri
  where ri.request_id = r.id
) li on true
where r.receiver_id = auth.uid();

comment on view public.my_requests is
  'The caller''s own requests. Position counts every request ahead - not just the caller''s.';

create view public.provider_public
with (security_invoker = true) as
select
  pr.id,
  pr.name,
  pr.description,
  pr.category,
  pr.location,
  pr.lat,
  pr.lng,
  pr.cover_url,
  pr.is_active,
  private.provider_queue_length(pr.id) as queue_length
from public.providers pr
where pr.is_active = true;

comment on view public.provider_public is
  'World-readable discovery surface. Queue COUNT only - never receiver identity.';

-- Dropping a view drops its grants.
grant select on public.provider_queue   to authenticated;
grant select on public.provider_archive to authenticated;
grant select on public.my_requests      to authenticated;
grant select on public.provider_public  to anon, authenticated;


-- -----------------------------------------------------------------------------
-- 4. Drop definer rights from every function that does not need them.
--    These operate on tables the caller already holds the right grants and RLS
--    policies for, so invoker rights suffice - and are strictly safer, because
--    RLS now backs up each function's own ownership check instead of being
--    bypassed by it.
-- -----------------------------------------------------------------------------
alter function public.upsert_profile(jsonb)              security invoker;
alter function public.upsert_provider(jsonb)             security invoker;
alter function public.set_provider_active(uuid, boolean) security invoker;
alter function public.upsert_item(jsonb)                 security invoker;
alter function public.set_item_visible(uuid, boolean)    security invoker;
alter function public.reorder_items(uuid, uuid[])        security invoker;
alter function public.delete_item(uuid)                  security invoker;
alter function public.my_provider()                      security invoker;
alter function public.provider_analytics(uuid, timestamptz, timestamptz) security invoker;

-- Still definer, and correctly so. These five write to `requests`, which no
-- client holds any write grant on. That is the core of the whole design:
--   create_request, start_request, finish_request, cancel_request, restore_request


-- -----------------------------------------------------------------------------
-- 5. Trigger functions are not API endpoints.
--    These were created before the default-privilege lockdown in migration
--    ...0300, so they kept Postgres's default "execute for PUBLIC" grant and
--    were reachable at /rest/v1/rpc/. Nothing good comes of that.
-- -----------------------------------------------------------------------------
revoke all on function public.handle_new_user() from public, anon, authenticated;
revoke all on function public.set_updated_at()  from public, anon, authenticated;

-- The last function without a pinned search_path.
alter function public.max_open_requests_per_provider() set search_path = '';
revoke all on function public.max_open_requests_per_provider() from public, anon, authenticated;
