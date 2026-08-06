-- =============================================================================
-- 20260806090300_rls
-- Tenancy isolation lives here, in the database. Not in the clients.
-- Implements docs/backend/security-rls.md.
--
-- Rule: writes to requests/request_items are NEVER granted to clients.
-- They happen only inside the security-definer RPCs. The absence of a
-- permissive write policy is the denial.
-- =============================================================================

alter table public.profiles      enable row level security;
alter table public.providers     enable row level security;
alter table public.items         enable row level security;
alter table public.requests      enable row level security;
alter table public.request_items enable row level security;

-- -----------------------------------------------------------------------------
-- Baseline privileges: revoke the default-permissive grants, then re-grant
-- exactly what the contract needs. RLS filters rows; GRANT gates verbs.
-- -----------------------------------------------------------------------------
revoke all on public.profiles      from anon, authenticated;
revoke all on public.providers     from anon, authenticated;
revoke all on public.items         from anon, authenticated;
revoke all on public.requests      from anon, authenticated;
revoke all on public.request_items from anon, authenticated;

grant select                         on public.profiles      to authenticated;
grant insert, update                 on public.profiles      to authenticated;
grant select                         on public.providers     to anon, authenticated;
grant insert, update, delete         on public.providers     to authenticated;
grant select                         on public.items         to anon, authenticated;
grant insert, update, delete         on public.items         to authenticated;
-- Read-only for clients. All mutations are RPC-only.
grant select                         on public.requests      to authenticated;
grant select                         on public.request_items to authenticated;

-- -----------------------------------------------------------------------------
-- profiles
-- -----------------------------------------------------------------------------
drop policy if exists profiles_self_read   on public.profiles;
drop policy if exists profiles_self_insert on public.profiles;
drop policy if exists profiles_self_update on public.profiles;

-- Own profile only. Other users' display names reach the UI exclusively
-- through the definer views (provider_queue / provider_archive).
create policy profiles_self_read on public.profiles
  for select to authenticated
  using (id = auth.uid());

create policy profiles_self_insert on public.profiles
  for insert to authenticated
  with check (id = auth.uid());

create policy profiles_self_update on public.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- -----------------------------------------------------------------------------
-- providers
-- -----------------------------------------------------------------------------
drop policy if exists providers_public_read on public.providers;
drop policy if exists providers_owner_read  on public.providers;
drop policy if exists providers_owner_write on public.providers;

-- Discovery: anyone, including guests, may see ACTIVE providers.
create policy providers_public_read on public.providers
  for select to anon, authenticated
  using (is_active = true);

-- Owners additionally see their own inactive providers.
create policy providers_owner_read on public.providers
  for select to authenticated
  using (owner_id = auth.uid());

create policy providers_owner_write on public.providers
  for all to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

-- -----------------------------------------------------------------------------
-- items
-- -----------------------------------------------------------------------------
drop policy if exists items_public_read on public.items;
drop policy if exists items_owner_all   on public.items;

-- Guests and receivers see VISIBLE items of ACTIVE providers. Nothing else.
create policy items_public_read on public.items
  for select to anon, authenticated
  using (
    is_visible = true
    and exists (
      select 1 from public.providers p
      where p.id = items.provider_id
        and p.is_active = true
    )
  );

-- Owners see and manage all their items, hidden ones included.
create policy items_owner_all on public.items
  for all to authenticated
  using (
    exists (
      select 1 from public.providers p
      where p.id = items.provider_id
        and p.owner_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from public.providers p
      where p.id = items.provider_id
        and p.owner_id = auth.uid()
    )
  );

-- -----------------------------------------------------------------------------
-- requests — SELECT only, for the two legitimate parties.
-- No INSERT/UPDATE/DELETE policy exists, by design.
-- -----------------------------------------------------------------------------
drop policy if exists requests_receiver_read on public.requests;
drop policy if exists requests_provider_read on public.requests;

create policy requests_receiver_read on public.requests
  for select to authenticated
  using (receiver_id = auth.uid());

create policy requests_provider_read on public.requests
  for select to authenticated
  using (
    exists (
      select 1 from public.providers p
      where p.id = requests.provider_id
        and p.owner_id = auth.uid()
    )
  );

-- -----------------------------------------------------------------------------
-- request_items — readable exactly when the parent request is readable.
-- -----------------------------------------------------------------------------
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
          or exists (
            select 1 from public.providers p
            where p.id = r.provider_id
              and p.owner_id = auth.uid()
          )
        )
    )
  );

-- -----------------------------------------------------------------------------
-- View grants
-- -----------------------------------------------------------------------------
revoke all on public.provider_queue   from anon, authenticated;
revoke all on public.provider_archive from anon, authenticated;
revoke all on public.my_requests      from anon, authenticated;
revoke all on public.provider_public  from anon, authenticated;

grant select on public.provider_queue   to authenticated;
grant select on public.provider_archive to authenticated;
grant select on public.my_requests      to authenticated;
grant select on public.provider_public  to anon, authenticated;

-- -----------------------------------------------------------------------------
-- Sequence: clients must never mint their own ordering keys.
-- -----------------------------------------------------------------------------
revoke all on sequence public.request_seq from anon, authenticated;

-- -----------------------------------------------------------------------------
-- Future objects default to closed rather than open.
-- -----------------------------------------------------------------------------
alter default privileges in schema public
  revoke all on tables from anon, authenticated;
alter default privileges in schema public
  revoke all on functions from anon, authenticated;
