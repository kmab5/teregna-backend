-- =============================================================================
-- 20260806090200_views
-- The read contract. Implements docs/architecture/api-contract.md.
--
-- SECURITY NOTE — why these are NOT security_invoker:
--   * provider_queue/provider_archive join profiles to show the receiver's
--     display name. RLS on profiles is self-read only, so an invoker-rights
--     view would return no name to the provider.
--   * my_requests must compute the receiver's TRUE position among all of the
--     provider's active requests — rows the receiver cannot read directly.
--   * provider_public exposes a queue-length count over requests, which
--     receivers cannot read row-by-row.
-- Each view therefore runs with definer rights and carries its OWN explicit
-- tenancy predicate (owner_id = auth.uid() / receiver_id = auth.uid()).
-- Never remove those predicates.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- provider_queue — the owning provider's live queue, oldest first.
-- -----------------------------------------------------------------------------
create or replace view public.provider_queue
with (security_invoker = false) as
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
  'Active requests for providers owned by the caller, with derived 1-based position.';

-- -----------------------------------------------------------------------------
-- provider_archive — completed and cancelled, most recent first.
-- -----------------------------------------------------------------------------
create or replace view public.provider_archive
with (security_invoker = false) as
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

-- -----------------------------------------------------------------------------
-- my_requests — the caller's own requests, with true live position.
-- -----------------------------------------------------------------------------
create or replace view public.my_requests
with (security_invoker = false) as
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
  case
    when r.status in ('queued', 'in_progress') then (
      select count(*)
      from public.requests r2
      where r2.provider_id = r.provider_id
        and r2.status in ('queued', 'in_progress')
        and r2.seq <= r.seq
    )
  end as position,
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
  'The caller''s own requests. Position counts ALL active requests ahead of it, not just the caller''s.';

-- -----------------------------------------------------------------------------
-- provider_public — discovery. Active providers only, public columns only,
-- plus a queue-length COUNT (never the identities behind it).
-- -----------------------------------------------------------------------------
create or replace view public.provider_public
with (security_invoker = false) as
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
  coalesce(q.cnt, 0)::int as queue_length
from public.providers pr
left join (
  select provider_id, count(*) as cnt
  from public.requests
  where status in ('queued', 'in_progress')
  group by provider_id
) q on q.provider_id = pr.id
where pr.is_active = true;

comment on view public.provider_public is
  'World-readable discovery surface. Exposes a queue COUNT only — never receiver identity.';
