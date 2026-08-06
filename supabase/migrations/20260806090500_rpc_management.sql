-- =============================================================================
-- 20260806090500_rpc_management
-- Provider, item and profile management.
--
-- These COULD be plain table writes under the owner RLS policies, and the
-- policies do back them up. They are exposed as RPCs anyway so that every
-- client speaks one verb vocabulary, and so ownership rules live in one place.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- upsert_profile — the caller's own profile.
-- -----------------------------------------------------------------------------
create or replace function public.upsert_profile(p jsonb)
returns public.profiles
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.profiles;
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = 'P0001';
  end if;

  update public.profiles
     set display_name = coalesce(nullif(btrim(p ->> 'display_name'), ''), display_name),
         avatar_url   = coalesce(p ->> 'avatar_url', avatar_url),
         phone        = coalesce(p ->> 'phone', phone),
         locale       = coalesce(nullif(p ->> 'locale', ''), locale)
   where id = v_uid
  returning * into v_row;

  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;

  return v_row;
end;
$$;

-- -----------------------------------------------------------------------------
-- upsert_provider — create or update the caller's provider.
-- Omit "id" to create. Supplying an id you do not own raises not_owner.
-- -----------------------------------------------------------------------------
create or replace function public.upsert_provider(p jsonb)
returns public.providers
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_id  uuid := nullif(p ->> 'id', '')::uuid;
  v_row public.providers;
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = 'P0001';
  end if;

  if v_id is null then
    insert into public.providers
      (owner_id, name, description, category, location, lat, lng, cover_url, is_active)
    values (
      v_uid,
      btrim(p ->> 'name'),
      p ->> 'description',
      nullif(btrim(coalesce(p ->> 'category', '')), ''),
      nullif(btrim(coalesce(p ->> 'location', '')), ''),
      nullif(p ->> 'lat', '')::numeric,
      nullif(p ->> 'lng', '')::numeric,
      p ->> 'cover_url',
      coalesce((p ->> 'is_active')::boolean, false)
    )
    returning * into v_row;
    return v_row;
  end if;

  update public.providers
     set name        = coalesce(nullif(btrim(p ->> 'name'), ''), name),
         description = coalesce(p ->> 'description', description),
         category    = coalesce(p ->> 'category', category),
         location    = coalesce(p ->> 'location', location),
         lat         = coalesce(nullif(p ->> 'lat', '')::numeric, lat),
         lng         = coalesce(nullif(p ->> 'lng', '')::numeric, lng),
         cover_url   = coalesce(p ->> 'cover_url', cover_url),
         is_active   = coalesce((p ->> 'is_active')::boolean, is_active)
   where id = v_id
     and owner_id = v_uid
  returning * into v_row;

  if not found then
    raise exception 'not_owner' using errcode = 'P0001';
  end if;

  return v_row;
end;
$$;

-- -----------------------------------------------------------------------------
-- set_provider_active — open or close shop.
-- Closing hides the provider from discovery and blocks NEW requests.
-- It deliberately does not touch the existing queue.
-- -----------------------------------------------------------------------------
create or replace function public.set_provider_active(
  p_provider_id uuid,
  p_active      boolean
)
returns public.providers
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_row public.providers;
begin
  update public.providers
     set is_active = p_active
   where id = p_provider_id
     and owner_id = auth.uid()
  returning * into v_row;

  if not found then
    raise exception 'not_owner' using errcode = 'P0001';
  end if;

  return v_row;
end;
$$;

-- -----------------------------------------------------------------------------
-- upsert_item
-- -----------------------------------------------------------------------------
create or replace function public.upsert_item(p jsonb)
returns public.items
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid         uuid := auth.uid();
  v_id          uuid := nullif(p ->> 'id', '')::uuid;
  v_provider_id uuid := nullif(p ->> 'provider_id', '')::uuid;
  v_row         public.items;
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = 'P0001';
  end if;

  if v_id is null then
    if not exists (
      select 1 from public.providers
       where id = v_provider_id and owner_id = v_uid
    ) then
      raise exception 'not_owner' using errcode = 'P0001';
    end if;

    insert into public.items
      (provider_id, name, description, price, currency, image_url, is_visible, display_order)
    values (
      v_provider_id,
      btrim(p ->> 'name'),
      p ->> 'description',
      nullif(p ->> 'price', '')::numeric,
      coalesce(nullif(p ->> 'currency', ''), 'ETB'),
      p ->> 'image_url',
      coalesce((p ->> 'is_visible')::boolean, true),
      coalesce((p ->> 'display_order')::int,
               (select coalesce(max(display_order), 0) + 1
                  from public.items where provider_id = v_provider_id))
    )
    returning * into v_row;
    return v_row;
  end if;

  update public.items i
     set name          = coalesce(nullif(btrim(p ->> 'name'), ''), i.name),
         description   = coalesce(p ->> 'description', i.description),
         price         = coalesce(nullif(p ->> 'price', '')::numeric, i.price),
         currency      = coalesce(nullif(p ->> 'currency', ''), i.currency),
         image_url     = coalesce(p ->> 'image_url', i.image_url),
         is_visible    = coalesce((p ->> 'is_visible')::boolean, i.is_visible),
         display_order = coalesce((p ->> 'display_order')::int, i.display_order)
   where i.id = v_id
     and exists (
       select 1 from public.providers pv
        where pv.id = i.provider_id and pv.owner_id = v_uid
     )
  returning * into v_row;

  if not found then
    raise exception 'not_owner' using errcode = 'P0001';
  end if;

  return v_row;
end;
$$;

-- -----------------------------------------------------------------------------
-- set_item_visible — instant, reversible. Hidden items vanish from receivers
-- immediately but never affect requests already placed.
-- -----------------------------------------------------------------------------
create or replace function public.set_item_visible(
  p_item_id uuid,
  p_visible boolean
)
returns public.items
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_row public.items;
begin
  update public.items i
     set is_visible = p_visible
   where i.id = p_item_id
     and exists (
       select 1 from public.providers pv
        where pv.id = i.provider_id and pv.owner_id = auth.uid()
     )
  returning * into v_row;

  if not found then
    raise exception 'not_owner' using errcode = 'P0001';
  end if;

  return v_row;
end;
$$;

-- -----------------------------------------------------------------------------
-- reorder_items — display_order follows the array index.
-- -----------------------------------------------------------------------------
create or replace function public.reorder_items(
  p_provider_id uuid,
  p_order       uuid[]
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not exists (
    select 1 from public.providers
     where id = p_provider_id and owner_id = auth.uid()
  ) then
    raise exception 'not_owner' using errcode = 'P0001';
  end if;

  update public.items i
     set display_order = o.ord
    from (
      select id, ordinality::int as ord
      from unnest(p_order) with ordinality as t(id, ordinality)
    ) o
   where i.id = o.id
     and i.provider_id = p_provider_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- delete_item — the item goes; the snapshots on past requests stay.
-- -----------------------------------------------------------------------------
create or replace function public.delete_item(p_item_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  delete from public.items i
   where i.id = p_item_id
     and exists (
       select 1 from public.providers pv
        where pv.id = i.provider_id and pv.owner_id = auth.uid()
     );

  if not found then
    raise exception 'not_owner' using errcode = 'P0001';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- my_provider — convenience: the caller's provider, or null.
-- Drives the "do I need onboarding?" branch in every client.
-- -----------------------------------------------------------------------------
create or replace function public.my_provider()
returns public.providers
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select * from public.providers
   where owner_id = auth.uid()
   order by created_at
   limit 1;
$$;

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------
revoke all on function public.upsert_profile(jsonb)              from public, anon;
revoke all on function public.upsert_provider(jsonb)             from public, anon;
revoke all on function public.set_provider_active(uuid, boolean) from public, anon;
revoke all on function public.upsert_item(jsonb)                 from public, anon;
revoke all on function public.set_item_visible(uuid, boolean)    from public, anon;
revoke all on function public.reorder_items(uuid, uuid[])        from public, anon;
revoke all on function public.delete_item(uuid)                  from public, anon;
revoke all on function public.my_provider()                      from public, anon;

grant execute on function public.upsert_profile(jsonb)              to authenticated;
grant execute on function public.upsert_provider(jsonb)             to authenticated;
grant execute on function public.set_provider_active(uuid, boolean) to authenticated;
grant execute on function public.upsert_item(jsonb)                 to authenticated;
grant execute on function public.set_item_visible(uuid, boolean)    to authenticated;
grant execute on function public.reorder_items(uuid, uuid[])        to authenticated;
grant execute on function public.delete_item(uuid)                  to authenticated;
grant execute on function public.my_provider()                      to authenticated;
