-- Tenancy isolation. A failure here blocks release.
-- Every assertion is "the wrong person sees or does nothing".
--
-- Seed-independent: test-only UUIDs, and every count scoped to these fixtures.
begin;
select plan(14);

insert into auth.users (id, email, raw_user_meta_data) values
  ('e2000000-0000-0000-0000-000000000001', 'i-owner@test.local', '{"display_name":"IsoOwner"}'),
  ('e2000000-0000-0000-0000-000000000002', 'i-rival@test.local', '{"display_name":"IsoRival"}'),
  ('e2000000-0000-0000-0000-000000000003', 'i-sara@test.local',  '{"display_name":"IsoSara"}');

-- The owner sets up shop with one visible and one hidden item.
set local role authenticated;
set local request.jwt.claims = '{"sub":"e2000000-0000-0000-0000-000000000001"}';

create temporary table t on commit drop as
select (public.upsert_provider('{"name":"Iso Barbershop","is_active":true}')).id as pid;

select public.upsert_item(jsonb_build_object(
  'provider_id', (select pid from t), 'name', 'Iso Haircut', 'price', 150));
select public.upsert_item(jsonb_build_object(
  'provider_id', (select pid from t), 'name', 'Iso Secret', 'price', 500, 'is_visible', false));

-- A receiver queues up.
set local request.jwt.claims = '{"sub":"e2000000-0000-0000-0000-000000000003"}';
create temporary table tr on commit drop as
select (public.create_request((select pid from t), '[]'::jsonb, 'iso note', 'iso-k1')).id as rid;

select is(
  (select count(*)::int from public.items where provider_id = (select pid from t)),
  1,
  'a receiver sees only VISIBLE items'
);

select is(
  (select count(*)::int from public.profiles),
  1,
  'a user can read only their OWN profile row'
);

-- --------------------------------------------------------------- the rival
-- A different provider, owning nothing here. They must see and do nothing.
set local request.jwt.claims = '{"sub":"e2000000-0000-0000-0000-000000000002"}';

select is(
  (select count(*)::int from public.requests
    where provider_id = (select pid from t)),
  0,
  'a rival provider cannot read another provider''s requests'
);

select is(
  (select count(*)::int from public.provider_queue),
  0,
  'a rival provider sees an empty provider_queue'
);

select is(
  (select count(*)::int from public.provider_archive),
  0,
  'a rival provider sees an empty provider_archive'
);

select is(
  (select count(*)::int from public.my_requests),
  0,
  'my_requests is scoped to the caller'
);

select is(
  (select count(*)::int from public.items where provider_id = (select pid from t)),
  1,
  'a rival cannot see another provider''s HIDDEN items'
);

select throws_ok(
  $$ select public.finish_request((select rid from tr)) $$,
  'P0001', 'not_owner',
  'a rival cannot finish another provider''s request'
);

select throws_ok(
  $$ select public.start_request((select rid from tr)) $$,
  'P0001', 'not_owner',
  'a rival cannot start another provider''s request'
);

select throws_ok(
  $$ select public.cancel_request((select rid from tr)) $$,
  'P0001', 'not_owner',
  'a rival cannot cancel someone else''s request'
);

select throws_ok(
  $$ select public.provider_analytics((select pid from t)) $$,
  'P0001', 'not_owner',
  'a rival cannot read another provider''s analytics'
);

select throws_ok(
  $$ select public.set_provider_active((select pid from t), false) $$,
  'P0001', 'not_owner',
  'a rival cannot close someone else''s shop'
);

select is(
  (select count(*)::int from public.request_items
    where request_id = (select rid from tr)),
  0,
  'a rival cannot read another provider''s line items'
);

-- ------------------------------------------------------------------- guests
-- anon holds no SELECT grant on requests at all, so this is refused at the
-- privilege layer before RLS is even consulted. Stronger than "returns 0 rows".
set local role anon;
set local request.jwt.claims = '{}';

select throws_ok(
  $$ select count(*) from public.requests $$,
  '42501',
  null,
  'a guest is denied access to requests outright'
);

select * from finish();
rollback;
