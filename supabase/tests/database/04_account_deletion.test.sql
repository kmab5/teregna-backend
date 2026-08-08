-- Deleting your own account must not destroy anyone else's records.
-- Seed-independent.
begin;
select plan(11);

insert into auth.users (id, email, raw_user_meta_data) values
  ('e4000000-0000-0000-0000-000000000001', 'd-owner@test.local', '{"display_name":"DelOwner"}'),
  ('e4000000-0000-0000-0000-000000000002', 'd-sara@test.local',  '{"display_name":"DelSara"}'),
  ('e4000000-0000-0000-0000-000000000003', 'd-solo@test.local',  '{"display_name":"DelSolo"}');

-- A provider who has actually served someone.
set local role authenticated;
set local request.jwt.claims = '{"sub":"e4000000-0000-0000-0000-000000000001"}';

create temporary table t on commit drop as
select (public.upsert_provider('{"name":"Del Barbershop","is_active":true}')).id as pid;
grant select on t to anon, authenticated;

select public.upsert_item(jsonb_build_object(
  'provider_id', (select pid from t), 'name', 'Del Haircut', 'price', 150,
  'duration_minutes', 30));

select is(
  (select duration_minutes from public.items where provider_id = (select pid from t)),
  30,
  'an item can carry a duration'
);

-- A receiver queues, is served, and keeps a completed request.
set local request.jwt.claims = '{"sub":"e4000000-0000-0000-0000-000000000002"}';
create temporary table tr on commit drop as
select (public.create_request((select pid from t), '[]'::jsonb, 'del note', 'del-k1')).id as rid;

set local request.jwt.claims = '{"sub":"e4000000-0000-0000-0000-000000000001"}';
select public.finish_request((select rid from tr));

-- A second live request, so we can prove it gets cancelled rather than stranded.
set local request.jwt.claims = '{"sub":"e4000000-0000-0000-0000-000000000002"}';
create temporary table tr2 on commit drop as
select (public.create_request((select pid from t), '[]'::jsonb, 'still waiting', 'del-k2')).id as rid2;

-- ------------------------------------------------- the provider deletes theirs
set local request.jwt.claims = '{"sub":"e4000000-0000-0000-0000-000000000001"}';

-- This is the case that was impossible before: providers cascaded from
-- profiles, but requests restricted deleting a provider.
select lives_ok(
  $$ select public.delete_my_account() $$,
  'a provider WITH request history can delete their account'
);

reset role;

select is(
  (select count(*)::int from public.profiles
    where id = 'e4000000-0000-0000-0000-000000000001'),
  0,
  'the profile is gone'
);

select is(
  (select count(*)::int from public.providers where id = (select pid from t)),
  1,
  'the provider row survives - the receiver has history attached to it'
);

select is(
  (select owner_id from public.providers where id = (select pid from t)),
  null,
  'the provider is orphaned rather than deleted'
);

select is(
  (select is_active from public.providers where id = (select pid from t)),
  false,
  'the orphaned provider is deactivated'
);

select is(
  (select status::text from public.requests where id = (select rid from tr)),
  'completed',
  'the completed request is untouched'
);

select is(
  (select status::text from public.requests where id = (select rid2 from tr2)),
  'cancelled',
  'the live request is cancelled, not left stranded'
);

select is(
  (select receiver_id from public.requests where id = (select rid from tr)),
  'e4000000-0000-0000-0000-000000000002'::uuid,
  'the receiver still owns their side of the record'
);

-- The receiver can still read their own history afterwards.
set local role authenticated;
set local request.jwt.claims = '{"sub":"e4000000-0000-0000-0000-000000000002"}';
select is(
  (select count(*)::int from public.my_requests where id = (select rid from tr)),
  1,
  'the receiver keeps seeing their request after the provider deletes'
);

-- An orphaned provider must never resurface in discovery.
reset role;
set local role anon;
select is(
  (select count(*)::int from public.provider_public where id = (select pid from t)),
  0,
  'an orphaned provider never appears in discovery'
);

-- A receiver-only account with no provider deletes cleanly too.
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"e4000000-0000-0000-0000-000000000003"}';
select lives_ok(
  $$ select public.delete_my_account() $$,
  'an account that owns nothing deletes cleanly'
);

select * from finish();
rollback;
