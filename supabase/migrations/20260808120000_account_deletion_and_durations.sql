-- =============================================================================
-- 20260808120000_account_deletion_and_durations
--
-- 1. Lets a person delete their own account without destroying anybody else's
--    records.
-- 2. Adds a per-item duration, which is the groundwork for showing an
--    estimated wait rather than only an elapsed one.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Ownership becomes severable.
--
-- Before this, `providers.owner_id` was NOT NULL and cascaded from profiles,
-- while `requests.provider_id` was ON DELETE RESTRICT. So deleting a profile
-- tried to delete their providers, which the restrict blocked the moment the
-- provider had a single request. Account deletion was impossible for any
-- provider who had ever served anyone.
--
-- A provider's request history is not only theirs - the receivers on the other
-- side of those rows have a right to their own history. So the provider row
-- survives and is orphaned: owner_id goes null, nobody can manage it, and it is
-- deactivated so it never appears in discovery again.
-- -----------------------------------------------------------------------------
alter table public.providers
  alter column owner_id drop not null;

alter table public.providers
  drop constraint if exists providers_owner_id_fkey;

alter table public.providers
  add constraint providers_owner_id_fkey
  foreign key (owner_id) references public.profiles (id) on delete set null;

comment on column public.providers.owner_id is
  'Null means the owner deleted their account. The row is retained (and inactive) because its request history belongs to the receivers too.';

-- An orphaned provider must never be publicly listed, whatever its is_active
-- flag says. Belt and braces alongside the deletion routine.
drop policy if exists providers_public_read on public.providers;
create policy providers_public_read on public.providers
  for select to anon, authenticated
  using (is_active = true and owner_id is not null);


-- -----------------------------------------------------------------------------
-- 2. How long a service takes.
--
-- Not yet used to compute an estimate - the queue shows elapsed time today.
-- Collecting it now means the estimate can be switched on without a migration
-- and without asking providers to re-enter their whole menu.
-- -----------------------------------------------------------------------------
alter table public.items
  add column if not exists duration_minutes integer
  check (duration_minutes is null or (duration_minutes > 0 and duration_minutes <= 1440));

comment on column public.items.duration_minutes is
  'Typical minutes to complete. Optional. Reserved for estimated wait times.';


-- -----------------------------------------------------------------------------
-- 3. Deleting your own account.
--
-- Order matters:
--   a. cancel anything live, so no one is left waiting on a ghost
--   b. drop providers that never served anyone - nothing to preserve
--   c. deactivate the rest
--   d. delete the auth user, which cascades to profiles and nulls out
--      providers.owner_id and requests.receiver_id
--
-- If (d) fails - the auth schema is owned by a different role and platform
-- policy can change - the transaction still leaves no personal data behind,
-- because the profile is scrubbed first. Losing the login row is recoverable;
-- leaving someone's name and phone number behind is not.
-- -----------------------------------------------------------------------------
create or replace function public.delete_my_account()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid       uuid := auth.uid();
  v_cancelled integer;
  v_orphaned  integer;
  v_auth_gone boolean := false;
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = 'P0001';
  end if;

  -- (a) Nobody should be left queued behind a person who no longer exists,
  --     in either direction.
  update public.requests r
     set status = 'cancelled',
         cancelled_at = now()
   where r.status in ('queued', 'in_progress')
     and (
       r.receiver_id = v_uid
       or r.provider_id in (
         select p.id from public.providers p where p.owner_id = v_uid
       )
     );
  get diagnostics v_cancelled = row_count;

  -- (b) A provider with no history has nothing worth preserving.
  delete from public.providers p
   where p.owner_id = v_uid
     and not exists (
       select 1 from public.requests r where r.provider_id = p.id
     );

  -- (c) Whatever remains goes dark before it is orphaned.
  update public.providers
     set is_active = false
   where owner_id = v_uid;
  get diagnostics v_orphaned = row_count;

  -- Scrub the profile first, so personal data is gone even if (d) cannot run.
  update public.profiles
     set display_name = 'Deleted user',
         avatar_url   = null,
         phone        = null
   where id = v_uid;

  -- (d) Remove the login itself.
  begin
    delete from auth.users where id = v_uid;
    v_auth_gone := true;
  exception
    when insufficient_privilege or others then
      v_auth_gone := false;
  end;

  return jsonb_build_object(
    'cancelled_requests', coalesce(v_cancelled, 0),
    'orphaned_providers', coalesce(v_orphaned, 0),
    'auth_user_deleted',  v_auth_gone
  );
end;
$$;

comment on function public.delete_my_account() is
  'Deletes the caller''s account. Retains orphaned provider rows so receivers keep their own history.';

revoke all    on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;


-- -----------------------------------------------------------------------------
-- 4. upsert_item learns about duration_minutes.
--
-- Replaced wholesale rather than patched, because migrations are append-only
-- and this is the authoritative definition from here on.
-- -----------------------------------------------------------------------------
create or replace function public.upsert_item(p jsonb)
returns public.items
language plpgsql
security invoker
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
      (provider_id, name, description, price, currency, image_url,
       is_visible, display_order, duration_minutes)
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
                  from public.items where provider_id = v_provider_id)),
      nullif(p ->> 'duration_minutes', '')::int
    )
    returning * into v_row;
    return v_row;
  end if;

  update public.items i
     set name             = coalesce(nullif(btrim(p ->> 'name'), ''), i.name),
         description      = coalesce(p ->> 'description', i.description),
         price            = coalesce(nullif(p ->> 'price', '')::numeric, i.price),
         currency         = coalesce(nullif(p ->> 'currency', ''), i.currency),
         image_url        = coalesce(p ->> 'image_url', i.image_url),
         is_visible       = coalesce((p ->> 'is_visible')::boolean, i.is_visible),
         display_order    = coalesce((p ->> 'display_order')::int, i.display_order),
         duration_minutes = coalesce(nullif(p ->> 'duration_minutes', '')::int,
                                     i.duration_minutes)
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

revoke all    on function public.upsert_item(jsonb) from public, anon;
grant execute on function public.upsert_item(jsonb) to authenticated;
