-- Structural contract. If these fail, a migration changed the shape the
-- clients depend on.
begin;
select plan(28);

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

select * from finish();
rollback;
