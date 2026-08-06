-- =============================================================================
-- 20260806090600_rpc_analytics
-- One call returns the whole dashboard. Implements docs/backend/analytics.md.
--
-- Definitions (keep these and the docs in lockstep):
--   total        : requests CREATED in the range
--   completed    : requests COMPLETED in the range
--   cancelled    : requests CANCELLED in the range
--   completion rate = completed / (completed + cancelled), null when denominator = 0
--   time to complete = completed_at - created_at (wall clock, includes waiting)
-- Restores are not counted as new requests; a restored-and-recompleted request
-- can therefore complete twice across two ranges. That is intentional and noted.
-- =============================================================================

create or replace function public.provider_analytics(
  p_provider_id uuid,
  p_range_start timestamptz default (now() - interval '30 days'),
  p_range_end   timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_tz     text := 'Africa/Addis_Ababa';
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'unauthenticated' using errcode = 'P0001';
  end if;

  if not exists (
    select 1 from public.providers
     where id = p_provider_id
       and owner_id = auth.uid()
  ) then
    raise exception 'not_owner' using errcode = 'P0001';
  end if;

  if p_range_end <= p_range_start then
    raise exception 'invalid_range' using errcode = 'P0001';
  end if;

  select jsonb_build_object(

    'range', jsonb_build_object(
      'start', p_range_start,
      'end',   p_range_end,
      'timezone', v_tz
    ),

    'totals', (
      select jsonb_build_object(
        'total',     count(*),
        'completed', count(*) filter (where status = 'completed'),
        'cancelled', count(*) filter (where status = 'cancelled'),
        'active',    count(*) filter (where status in ('queued', 'in_progress'))
      )
      from public.requests
      where provider_id = p_provider_id
        and created_at >= p_range_start
        and created_at <  p_range_end
    ),

    -- Live, not range-bound: what is waiting right now.
    'current_queue_length', (
      select count(*)
      from public.requests
      where provider_id = p_provider_id
        and status in ('queued', 'in_progress')
    ),

    'completion_rate', (
      select case
               when count(*) filter (where status in ('completed', 'cancelled')) = 0
                 then null
               else round(
                 count(*) filter (where status = 'completed')::numeric
                 / count(*) filter (where status in ('completed', 'cancelled'))::numeric,
                 4)
             end
      from public.requests
      where provider_id = p_provider_id
        and created_at >= p_range_start
        and created_at <  p_range_end
    ),

    'avg_time_to_complete_seconds', (
      select coalesce(
               round(avg(extract(epoch from (completed_at - created_at)))::numeric, 1),
               0)
      from public.requests
      where provider_id = p_provider_id
        and status = 'completed'
        and completed_at >= p_range_start
        and completed_at <  p_range_end
    ),

    'median_time_to_complete_seconds', (
      select coalesce(
               round(percentile_cont(0.5) within group (
                 order by extract(epoch from (completed_at - created_at))
               )::numeric, 1),
               0)
      from public.requests
      where provider_id = p_provider_id
        and status = 'completed'
        and completed_at >= p_range_start
        and completed_at <  p_range_end
    ),

    -- Dense daily series: zero-filled so the chart has no phantom gaps.
    'over_time', (
      select coalesce(
               jsonb_agg(
                 jsonb_build_object('day', d.day, 'count', coalesce(c.cnt, 0))
                 order by d.day
               ),
               '[]'::jsonb)
      from generate_series(
             date_trunc('day', p_range_start at time zone v_tz),
             date_trunc('day', p_range_end   at time zone v_tz),
             interval '1 day'
           ) as d(day)
      left join (
        select date_trunc('day', created_at at time zone v_tz) as day,
               count(*) as cnt
        from public.requests
        where provider_id = p_provider_id
          and created_at >= p_range_start
          and created_at <  p_range_end
        group by 1
      ) c on c.day = d.day
    ),

    'by_item', (
      select coalesce(
               jsonb_agg(
                 jsonb_build_object('item', t.name, 'count', t.cnt, 'quantity', t.qty)
                 order by t.cnt desc, t.name
               ),
               '[]'::jsonb)
      from (
        select ri.item_name_snapshot as name,
               count(distinct ri.request_id) as cnt,
               sum(ri.quantity) as qty
        from public.request_items ri
        join public.requests r on r.id = ri.request_id
        where r.provider_id = p_provider_id
          and r.created_at >= p_range_start
          and r.created_at <  p_range_end
        group by 1
      ) t
    ),

    -- All 24 hours present, zero-filled, in provider-local time.
    'busiest_hours', (
      select coalesce(
               jsonb_agg(
                 jsonb_build_object('hour', h.hour, 'count', coalesce(c.cnt, 0))
                 order by h.hour
               ),
               '[]'::jsonb)
      from generate_series(0, 23) as h(hour)
      left join (
        select extract(hour from created_at at time zone v_tz)::int as hour,
               count(*) as cnt
        from public.requests
        where provider_id = p_provider_id
          and created_at >= p_range_start
          and created_at <  p_range_end
        group by 1
      ) c on c.hour = h.hour
    )

  ) into v_result;

  return v_result;
end;
$$;

revoke all    on function public.provider_analytics(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.provider_analytics(uuid, timestamptz, timestamptz) to authenticated;
