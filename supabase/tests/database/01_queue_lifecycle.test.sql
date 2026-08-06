-- The core loop: send -> queue -> start -> finish -> archive -> restore.
-- Plus ordering, idempotency, and the open-request cap.
--
-- NOTE: these tests run AFTER seed.sql, so they must be seed-independent.
-- Use test-only UUIDs and scope every count to the fixtures created here.
begin;
select plan(22);

-- ---------------------------------------------------------------- fixtures
insert into auth.users (id, email, raw_user_meta_data) values
  ('e1000000-0000-0000-0000-000000000001', 't-owner@test.local',  '{"display_name":"TestOwner"}'),
  ('e1000000-0000-0000-0000-000000000002', 't-sara@test.local',   '{"display_name":"TestSara"}'),
  ('e1000000-0000-0000-0000-000000000003', 't-dawit@test.local',  '{"display_name":"TestDawit"}');

select is(
  (select count(*)::int from public.profiles
    where id in ('e1000000-0000-0000-0000-000000000001',
                 'e1000000-0000-0000-0000-000000000002',
                 'e1000000-0000-0000-0000-000000000003')),
  3,
  'a profile is auto-created for every new auth user'
);

-- ------------------------------------------------------------ provider setup
set local role authenticated;
set local request.jwt.claims = '{"sub":"e1000000-0000-0000-0000-000000000001"}';

create temporary table t_ids on commit drop as
select (public.upsert_provider('{"name":"Test Barbershop","category":"barber"}')).id as provider_id;

create temporary table t_items on commit drop as
select (public.upsert_item(
  jsonb_build_object('provider_id', (select provider_id from t_ids),
                     'name', 'Haircut', 'price', 150)
)).id as haircut_id;

select lives_ok(
  $$ select public.set_provider_active((select provider_id from t_ids), true) $$,
  'provider can open shop'
);

select is(
  (select count(*)::int from public.provider_public
    where id = (select provider_id from t_ids)),
  1,
  'an active provider appears in discovery'
);

-- ------------------------------------------------------------ receiver sends
set local request.jwt.claims = '{"sub":"e1000000-0000-0000-0000-000000000002"}';

create temporary table t_req on commit drop as
select (public.create_request(
  (select provider_id from t_ids),
  jsonb_build_array(jsonb_build_object('item_id', (select haircut_id from t_items), 'quantity', 1)),
  'first request',
  'test-idem-1'
)).id as r1;

select is(
  (select status::text from public.requests where id = (select r1 from t_req)),
  'queued',
  'a new request lands in the queue'
);

select is(
  (select position::int from public.my_requests where id = (select r1 from t_req)),
  1,
  'the first request is position 1'
);

select is(
  (select jsonb_array_length(items) from public.my_requests where id = (select r1 from t_req)),
  1,
  'line items are snapshotted onto the request'
);

-- Idempotency: the same key must never enqueue twice.
select is(
  (public.create_request((select provider_id from t_ids), '[]'::jsonb, null, 'test-idem-1')).id,
  (select r1 from t_req),
  'replaying an idempotency key returns the original request'
);

select is(
  (select count(*)::int from public.requests
    where provider_id = (select provider_id from t_ids)),
  1,
  'replaying an idempotency key creates NO duplicate row'
);

-- Direct table writes are denied. This is the guarantee the design rests on.
select throws_ok(
  $$ update public.requests set status = 'completed'
      where id = (select r1 from t_req) $$,
  '42501',
  null,
  'a receiver cannot write requests directly - RPC only'
);

-- Open-request cap.
select lives_ok(
  $$ select public.create_request((select provider_id from t_ids), '[]'::jsonb, 'second', 'test-idem-2') $$,
  'second concurrent request allowed'
);
select lives_ok(
  $$ select public.create_request((select provider_id from t_ids), '[]'::jsonb, 'third', 'test-idem-3') $$,
  'third concurrent request allowed'
);
select throws_ok(
  $$ select public.create_request((select provider_id from t_ids), '[]'::jsonb, 'fourth', 'test-idem-4') $$,
  'P0001',
  'too_many_open_requests',
  'a fourth open request to the same provider is refused'
);

-- ------------------------------------------------- a second receiver queues up
set local request.jwt.claims = '{"sub":"e1000000-0000-0000-0000-000000000003"}';

create temporary table t_req2 on commit drop as
select (public.create_request((select provider_id from t_ids), '[]'::jsonb, 'dawit', 'test-idem-d1')).id as rd;

select is(
  (select position::int from public.my_requests where id = (select rd from t_req2)),
  4,
  'position counts EVERY request ahead, not just the caller''s own'
);

-- ------------------------------------------------------- provider works queue
set local request.jwt.claims = '{"sub":"e1000000-0000-0000-0000-000000000001"}';

select is(
  (select count(*)::int from public.provider_queue),
  4,
  'the provider sees the whole live queue'
);

select is(
  (select receiver_name from public.provider_queue where position = 1),
  'TestSara',
  'the queue is ordered oldest-first and names the receiver'
);

select is(
  (public.start_request((select r1 from t_req))).status::text,
  'in_progress',
  'queued -> in_progress'
);

select is(
  (public.finish_request((select r1 from t_req))).status::text,
  'completed',
  'in_progress -> completed'
);

select is(
  (select count(*)::int from public.provider_queue),
  3,
  'finishing removes the request from the live queue'
);

select is(
  (select count(*)::int from public.provider_archive
    where id = (select r1 from t_req)),
  1,
  'finishing archives the request'
);

-- ------------------------------------------------------------------- restore
select is(
  (public.restore_request((select r1 from t_req), 'back')).status::text,
  'queued',
  'an archived request can always be restored'
);

select is(
  (select position::int from public.provider_queue where id = (select r1 from t_req)),
  4,
  'restore with mode=back sends it to the end of the queue'
);

select throws_ok(
  $$ select public.restore_request((select r1 from t_req), 'back') $$,
  'P0001',
  'not_archived',
  'restoring an already-active request is refused'
);

select * from finish();
rollback;
