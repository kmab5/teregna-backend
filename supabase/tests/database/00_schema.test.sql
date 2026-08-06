-- Structural contract. If these fail, a migration changed the shape the
-- clients depend on.
begin;
select plan(34);

-- Tables
select has_table('public', 'profiles',      'profiles exists');
select has_table('public', 'providers',     'providers exists');
select has_table('public', 'items',         'items exists');
select has_table('public', 'requests',      'requests exists');
select has_table('public', 'request_items', 'request_items exists');

-- Enum values, exactly these four, in this order
select has_type('public', 'request_status', 'request_status enum exists');
select enum_has_labels(
  'public', 'request_status',
  array['queued', 'in_progress', 'completed', 'cancelled'],
  'request_status has exactly the four canonical states'
);

-- Views (the read contract)
select has_view('public', 'provider_queue',   'provider_queue exists');
select has_view('public', 'provider_archive', 'provider_archive exists');
select has_view('public', 'my_requests',      'my_requests exists');
select has_view('public', 'provider_public',  'provider_public exists');

-- Position must be derived, never stored
select hasnt_column('public', 'requests', 'position',
  'requests has NO stored position column - it is always derived from seq');
select has_column('public', 'requests', 'seq',
  'requests.seq is the ordering key');

-- Snapshots
select has_column('public', 'request_items', 'item_name_snapshot',
  'line items snapshot the item name');
select has_column('public', 'request_items', 'item_price_snapshot',
  'line items snapshot the item price');

-- RLS is on everywhere it matters
select ok(relrowsecurity, 'RLS enabled on profiles')
  from pg_class where oid = 'public.profiles'::regclass;
select ok(relrowsecurity, 'RLS enabled on providers')
  from pg_class where oid = 'public.providers'::regclass;
select ok(relrowsecurity, 'RLS enabled on items')
  from pg_class where oid = 'public.items'::regclass;
select ok(relrowsecurity, 'RLS enabled on requests')
  from pg_class where oid = 'public.requests'::regclass;
select ok(relrowsecurity, 'RLS enabled on request_items')
  from pg_class where oid = 'public.request_items'::regclass;

-- RPC surface
select has_function('public', 'create_request',  'create_request exists');
select has_function('public', 'start_request',   'start_request exists');
select has_function('public', 'finish_request',  'finish_request exists');
select has_function('public', 'cancel_request',  'cancel_request exists');
select has_function('public', 'restore_request', 'restore_request exists');
select has_function('public', 'provider_analytics', 'provider_analytics exists');

-- Every mutating RPC must be definer AND have a pinned search_path.
-- An unpinned definer function is a privilege-escalation hole.
select is_empty($$
  select p.proname
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prosecdef
    and (p.proconfig is null or not exists (
      select 1 from unnest(p.proconfig) c where c like 'search_path=%'
    ))
$$, 'every security definer function pins search_path');

-- Clients must hold no write grant on requests. Writes are RPC-only.
select is_empty($$
  select privilege_type
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name = 'requests'
    and grantee in ('anon', 'authenticated')
    and privilege_type in ('INSERT', 'UPDATE', 'DELETE')
$$, 'anon/authenticated hold NO write grant on requests');

-- ---------------------------------------------------------------------------
-- Advisor-hardening invariants. These encode decisions, not preferences:
-- regressing any of them reopens a finding the Supabase linter raises.
-- ---------------------------------------------------------------------------

-- Every Teregna view must run with INVOKER rights so base-table RLS applies.
-- A definer view makes its own WHERE clause the only tenancy boundary.
select is_empty($$
  select c.relname
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind = 'v'
    and c.relname in ('provider_queue','provider_archive','my_requests','provider_public')
    and not coalesce(
      (select o.option_value = 'true'
       from pg_options_to_table(c.reloptions) o
       where o.option_name = 'security_invoker'),
      false)
$$, 'all four views run with security_invoker - RLS is not bypassed');

-- SECURITY DEFINER in the API-exposed schema is limited to the five functions
-- that must write to `requests`, plus two trigger/maintenance functions that
-- carry no EXECUTE grant.
select set_eq($$
  select p.proname::text
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosecdef
$$, array[
  'create_request','start_request','finish_request','cancel_request','restore_request',
  'handle_new_user','anonymize_profile'
], 'only the expected functions are SECURITY DEFINER in public');

-- Nothing SECURITY DEFINER may be reachable by an unauthenticated caller.
select is_empty($$
  select p.proname
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prosecdef
    and has_function_privilege('anon', p.oid, 'EXECUTE')
$$, 'no SECURITY DEFINER function in public is executable by anon');

-- Trigger and maintenance functions are not API endpoints.
select is_empty($$
  select p.proname
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('handle_new_user','set_updated_at','anonymize_profile',
                      'max_open_requests_per_provider')
    and (has_function_privilege('anon', p.oid, 'EXECUTE')
         or has_function_privilege('authenticated', p.oid, 'EXECUTE'))
$$, 'trigger and maintenance functions carry no EXECUTE grant');

-- Every Teregna function pins search_path, definer or not. The earlier check
-- only covered definer functions, which let one slip through.
select is_empty($$
  select p.proname
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public', 'private')
    and p.prokind = 'f'
    and p.proname in (
      'create_request','start_request','finish_request','cancel_request','restore_request',
      'upsert_provider','set_provider_active','upsert_item','set_item_visible',
      'reorder_items','delete_item','upsert_profile','my_provider','provider_analytics',
      'handle_new_user','set_updated_at','anonymize_profile','max_open_requests_per_provider',
      'is_provider_owner','has_request_with_provider','is_queue_counterparty',
      'request_position','provider_queue_length')
    and (p.proconfig is null or not exists (
      select 1 from unnest(p.proconfig) c where c like 'search_path=%'
    ))
$$, 'every Teregna function pins search_path');

-- The cross-tenancy helpers live outside the API-exposed schema.
select has_schema('private', 'the private schema exists and is not exposed via PostgREST');

select * from finish();
rollback;
