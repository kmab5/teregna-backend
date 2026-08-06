-- =============================================================================
-- 20260806090400_rpc_requests
-- The only path by which a request may be written.
--
-- Every function here:
--   * is security definer (clients hold no write grant on requests),
--   * pins search_path (no search-path hijack),
--   * re-checks ownership itself (definer rights are not a licence to skip it),
--   * locks the row before validating the transition (no lost updates),
--   * raises a named error from the shared error model.
-- Implements docs/backend/api-reference.md.
-- =============================================================================

-- Max simultaneously-open requests one receiver may hold with one provider.
create or replace function public.max_open_requests_per_provider()
returns integer
language sql
immutable
as $$ select 3 $$;

-- -----------------------------------------------------------------------------
-- create_request — receiver enqueues.
-- Errors: unauthenticated, provider_inactive, too_many_open_requests, invalid_item
-- -----------------------------------------------------------------------------
create or replace function public.create_request(
  p_provider_id     uuid,
  p_items           jsonb default '[]'::jsonb,   -- [{"item_id": uuid, "quantity": int}]
  p_note            text  default null,
  p_idempotency_key text  default null
)
returns public.requests
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid       uuid := auth.uid();
  v_req       public.requests;
  v_open      integer;
  v_requested integer;
  v_matched   integer;
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = 'P0001';
  end if;

  -- Idempotency first: a retry must return the original, not a duplicate.
  if p_idempotency_key is not null then
    select * into v_req
      from public.requests
     where provider_id     = p_provider_id
       and receiver_id     = v_uid
       and idempotency_key = p_idempotency_key;
    if found then
      return v_req;
    end if;
  end if;

  -- Lock the provider row so it cannot go inactive between check and insert.
  perform 1
     from public.providers
    where id = p_provider_id
      and is_active = true
      for share;
  if not found then
    raise exception 'provider_inactive' using errcode = 'P0001';
  end if;

  select count(*) into v_open
    from public.requests
   where provider_id = p_provider_id
     and receiver_id = v_uid
     and status in ('queued', 'in_progress');

  if v_open >= public.max_open_requests_per_provider() then
    raise exception 'too_many_open_requests' using errcode = 'P0001';
  end if;

  insert into public.requests (provider_id, receiver_id, note, idempotency_key)
  values (p_provider_id, v_uid, nullif(btrim(p_note), ''), p_idempotency_key)
  returning * into v_req;

  -- Snapshot the line items. Only visible items of THIS provider qualify.
  if jsonb_typeof(p_items) = 'array' and jsonb_array_length(p_items) > 0 then

    select count(*) into v_requested
      from jsonb_array_elements(p_items);

    with requested as (
      select (e ->> 'item_id')::uuid                  as item_id,
             coalesce((e ->> 'quantity')::int, 1)     as quantity
      from jsonb_array_elements(p_items) e
    ),
    inserted as (
      insert into public.request_items
        (request_id, item_id, item_name_snapshot, item_price_snapshot, quantity)
      select v_req.id, i.id, i.name, i.price, greatest(rq.quantity, 1)
        from requested rq
        join public.items i
          on i.id          = rq.item_id
         and i.provider_id = p_provider_id
         and i.is_visible  = true
      returning 1
    )
    select count(*) into v_matched from inserted;

    -- A silently-dropped item would mean the receiver ordered something the
    -- provider never sees. Fail loudly instead.
    if v_matched <> v_requested then
      raise exception 'invalid_item' using errcode = 'P0001';
    end if;
  end if;

  return v_req;
exception
  when unique_violation then
    -- Concurrent double-submit with the same idempotency key.
    select * into v_req
      from public.requests
     where provider_id     = p_provider_id
       and receiver_id     = v_uid
       and idempotency_key = p_idempotency_key;
    if found then
      return v_req;
    end if;
    raise exception 'duplicate_request' using errcode = 'P0001';
end;
$$;

-- -----------------------------------------------------------------------------
-- start_request — provider begins work. queued -> in_progress.
-- -----------------------------------------------------------------------------
create or replace function public.start_request(p_request_id uuid)
returns public.requests
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_req public.requests;
begin
  if auth.uid() is null then
    raise exception 'unauthenticated' using errcode = 'P0001';
  end if;

  select r.* into v_req
    from public.requests r
    join public.providers p on p.id = r.provider_id
   where r.id = p_request_id
     and p.owner_id = auth.uid()
     for no key update of r;

  if not found then
    raise exception 'not_owner' using errcode = 'P0001';
  end if;

  if v_req.status <> 'queued' then
    raise exception 'invalid_transition' using errcode = 'P0001';
  end if;

  update public.requests
     set status = 'in_progress',
         started_at = now()
   where id = p_request_id
  returning * into v_req;

  return v_req;
end;
$$;

-- -----------------------------------------------------------------------------
-- finish_request — provider completes. queued|in_progress -> completed.
-- This is the archiving action: completion IS archival.
-- -----------------------------------------------------------------------------
create or replace function public.finish_request(p_request_id uuid)
returns public.requests
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_req public.requests;
begin
  if auth.uid() is null then
    raise exception 'unauthenticated' using errcode = 'P0001';
  end if;

  select r.* into v_req
    from public.requests r
    join public.providers p on p.id = r.provider_id
   where r.id = p_request_id
     and p.owner_id = auth.uid()
     for no key update of r;

  if not found then
    raise exception 'not_owner' using errcode = 'P0001';
  end if;

  if v_req.status not in ('queued', 'in_progress') then
    raise exception 'invalid_transition' using errcode = 'P0001';
  end if;

  update public.requests
     set status = 'completed',
         completed_at = now(),
         started_at = coalesce(started_at, now())
   where id = p_request_id
  returning * into v_req;

  return v_req;
end;
$$;

-- -----------------------------------------------------------------------------
-- cancel_request — either party may cancel an active request.
-- -----------------------------------------------------------------------------
create or replace function public.cancel_request(p_request_id uuid)
returns public.requests
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_out public.requests;
begin
  if auth.uid() is null then
    raise exception 'unauthenticated' using errcode = 'P0001';
  end if;

  -- Lock the row first; either party may cancel, so the predicate covers both.
  perform 1
    from public.requests r
   where r.id = p_request_id
     and (
       r.receiver_id = auth.uid()
       or exists (
         select 1 from public.providers p
         where p.id = r.provider_id
           and p.owner_id = auth.uid()
       )
     )
     for no key update of r;

  if not found then
    raise exception 'not_owner' using errcode = 'P0001';
  end if;

  select * into v_out from public.requests where id = p_request_id;

  if v_out.status not in ('queued', 'in_progress') then
    raise exception 'invalid_transition' using errcode = 'P0001';
  end if;

  update public.requests
     set status = 'cancelled',
         cancelled_at = now()
   where id = p_request_id
  returning * into v_out;

  return v_out;
end;
$$;

-- -----------------------------------------------------------------------------
-- restore_request — the undo. Archived -> queued.
--   'back'     (default) : fresh seq, joins the end of the queue
--   'original'           : keeps its old seq, lands back in its old slot
-- Nothing is ever truly gone; this is always available.
-- -----------------------------------------------------------------------------
create or replace function public.restore_request(
  p_request_id uuid,
  p_mode       text default 'back'
)
returns public.requests
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_req public.requests;
begin
  if auth.uid() is null then
    raise exception 'unauthenticated' using errcode = 'P0001';
  end if;

  if p_mode not in ('back', 'original') then
    raise exception 'invalid_mode' using errcode = 'P0001';
  end if;

  select r.* into v_req
    from public.requests r
    join public.providers p on p.id = r.provider_id
   where r.id = p_request_id
     and p.owner_id = auth.uid()
     for no key update of r;

  if not found then
    raise exception 'not_owner' using errcode = 'P0001';
  end if;

  if v_req.status not in ('completed', 'cancelled') then
    raise exception 'not_archived' using errcode = 'P0001';
  end if;

  update public.requests
     set status       = 'queued',
         started_at   = null,
         completed_at = null,
         cancelled_at = null,
         seq          = case
                          when p_mode = 'back' then nextval('public.request_seq')
                          else seq
                        end
   where id = p_request_id
  returning * into v_req;

  return v_req;
end;
$$;

-- -----------------------------------------------------------------------------
-- Execution grants: authenticated callers only. anon holds nothing.
-- -----------------------------------------------------------------------------
revoke all on function public.create_request(uuid, jsonb, text, text) from public, anon;
revoke all on function public.start_request(uuid)                     from public, anon;
revoke all on function public.finish_request(uuid)                    from public, anon;
revoke all on function public.cancel_request(uuid)                    from public, anon;
revoke all on function public.restore_request(uuid, text)             from public, anon;

grant execute on function public.create_request(uuid, jsonb, text, text) to authenticated;
grant execute on function public.start_request(uuid)                     to authenticated;
grant execute on function public.finish_request(uuid)                    to authenticated;
grant execute on function public.cancel_request(uuid)                    to authenticated;
grant execute on function public.restore_request(uuid, text)             to authenticated;
