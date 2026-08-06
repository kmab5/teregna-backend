-- =============================================================================
-- 20260806090000_init_schema
-- Core domain: profiles, providers, items, requests, request_items.
-- Implements docs/architecture/data-model.md.
-- =============================================================================

create extension if not exists pgcrypto with schema extensions;

-- -----------------------------------------------------------------------------
-- Enum: request lifecycle
-- Active queue  = ('queued','in_progress')
-- Archive       = ('completed','cancelled')
-- -----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type where typname = 'request_status') then
    create type public.request_status as enum
      ('queued', 'in_progress', 'completed', 'cancelled');
  end if;
end
$$;

-- -----------------------------------------------------------------------------
-- Global monotonic ordering key.
-- Order is per-provider (seq ASC among active rows), but a single global
-- sequence makes assignment trivial, race-free, and gap-tolerant.
-- Restoring a request to the back of the queue = assign a fresh nextval.
-- -----------------------------------------------------------------------------
create sequence if not exists public.request_seq as bigint start 1;

-- -----------------------------------------------------------------------------
-- profiles — one row per auth user. Created automatically by trigger.
-- -----------------------------------------------------------------------------
create table if not exists public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  display_name text not null default 'User',
  avatar_url   text,
  phone        text,
  locale       text not null default 'en' check (locale in ('en', 'am')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

comment on table public.profiles is
  'Public-facing user record. One per auth.users row. PII beyond display_name is not exposed to other users.';

-- -----------------------------------------------------------------------------
-- providers — a user becomes a provider by owning a row here.
-- There is no role column: provider capability IS ownership.
-- -----------------------------------------------------------------------------
create table if not exists public.providers (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references public.profiles (id) on delete cascade,
  name        text not null check (length(btrim(name)) between 1 and 120),
  description text check (length(description) <= 2000),
  category    text,
  location    text,
  lat         numeric(9, 6) check (lat between -90 and 90),
  lng         numeric(9, 6) check (lng between -180 and 180),
  cover_url   text,
  is_active   boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on column public.providers.is_active is
  'False = closed. Hidden from discovery and rejects new requests, but the existing queue is preserved.';

create index if not exists providers_active_category_idx
  on public.providers (is_active, category);
create index if not exists providers_owner_idx
  on public.providers (owner_id);
-- Trigram search over provider names for discovery.
create extension if not exists pg_trgm with schema extensions;
create index if not exists providers_name_trgm_idx
  on public.providers using gin (name extensions.gin_trgm_ops);

-- -----------------------------------------------------------------------------
-- items — what a provider offers. Visibility is per-item and instant.
-- -----------------------------------------------------------------------------
create table if not exists public.items (
  id            uuid primary key default gen_random_uuid(),
  provider_id   uuid not null references public.providers (id) on delete cascade,
  name          text not null check (length(btrim(name)) between 1 and 120),
  description   text check (length(description) <= 1000),
  price         numeric(12, 2) check (price >= 0),
  currency      text not null default 'ETB',
  image_url     text,
  is_visible    boolean not null default true,
  display_order integer not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists items_provider_visible_order_idx
  on public.items (provider_id, is_visible, display_order);

-- -----------------------------------------------------------------------------
-- requests — the queue itself.
-- Position is DERIVED from seq at read time and never stored.
-- All writes go through RPC (see 20260806090400_rpc_requests.sql).
-- -----------------------------------------------------------------------------
create table if not exists public.requests (
  id              uuid primary key default gen_random_uuid(),
  provider_id     uuid not null references public.providers (id) on delete restrict,
  -- Nullable so a deleted receiver account leaves the provider's history intact
  -- (rendered as "Deleted user"). Never null at creation time.
  receiver_id     uuid references public.profiles (id) on delete set null,
  status          public.request_status not null default 'queued',
  seq             bigint not null default nextval('public.request_seq'),
  note            text check (length(note) <= 500),
  idempotency_key text,
  created_at      timestamptz not null default now(),
  started_at      timestamptz,
  completed_at    timestamptz,
  cancelled_at    timestamptz,
  constraint requests_terminal_timestamps_ck check (
    (status <> 'completed' or completed_at is not null) and
    (status <> 'cancelled' or cancelled_at is not null)
  )
);

comment on column public.requests.seq is
  'Monotonic ordering key. Active queue is ordered by seq ASC within a provider.';

-- Hot path: the provider''s live queue.
create index if not exists requests_provider_status_seq_idx
  on public.requests (provider_id, status, seq);

-- Receiver's "my requests".
create index if not exists requests_receiver_status_idx
  on public.requests (receiver_id, status);

-- Analytics time-bucketing.
create index if not exists requests_provider_created_idx
  on public.requests (provider_id, created_at);

-- De-duplicate double submissions from the same receiver to the same provider.
create unique index if not exists requests_idempotency_uidx
  on public.requests (provider_id, receiver_id, idempotency_key)
  where idempotency_key is not null;

-- -----------------------------------------------------------------------------
-- request_items — line items, SNAPSHOTTED.
-- Name and price are copied at request time so later item edits or deletions
-- never rewrite history.
-- -----------------------------------------------------------------------------
create table if not exists public.request_items (
  id                  uuid primary key default gen_random_uuid(),
  request_id          uuid not null references public.requests (id) on delete cascade,
  item_id             uuid references public.items (id) on delete set null,
  item_name_snapshot  text not null,
  item_price_snapshot numeric(12, 2),
  quantity            integer not null default 1 check (quantity > 0 and quantity <= 999)
);

create index if not exists request_items_request_idx
  on public.request_items (request_id);

-- -----------------------------------------------------------------------------
-- updated_at maintenance
-- -----------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

drop trigger if exists providers_set_updated_at on public.providers;
create trigger providers_set_updated_at
  before update on public.providers
  for each row execute function public.set_updated_at();

drop trigger if exists items_set_updated_at on public.items;
create trigger items_set_updated_at
  before update on public.items
  for each row execute function public.set_updated_at();
