-- What a receiver may and may not do, plus provider-inactive handling.
-- Seed-independent.
begin;
select plan(8);

insert into auth.users (id, email, raw_user_meta_data) values
  ('e3000000-0000-0000-0000-000000000001', 'r-owner@test.local', '{"display_name":"RcvOwner"}'),
  ('e3000000-0000-0000-0000-000000000002', 'r-sara@test.local',  '{"display_name":"RcvSara"}');

set local role authenticated;
set local request.jwt.claims = '{"sub":"e3000000-0000-0000-0000-000000000001"}';

create temporary table t on commit drop as
select (public.upsert_provider('{"name":"Rcv Barbershop","is_active":true}')).id as pid;

select public.upsert_item(jsonb_build_object(
  'provider_id', (select pid from t), 'name', 'Rcv Haircut', 'price', 150));

-- A receiver may cancel their own request.
set local request.jwt.claims = '{"sub":"e3000000-0000-0000-0000-000000000002"}';
create temporary table tr on commit drop as
select (public.create_request((select pid from t), '[]'::jsonb, null, 'rcv-k1')).id as rid;

select is(
  (public.cancel_request((select rid from tr))).status::text,
  'cancelled',
  'a receiver may cancel their own active request'
);

select throws_ok(
  $$ select public.cancel_request((select rid from tr)) $$,
  'P0001', 'invalid_transition',
  'cancelling an already-cancelled request is refused'
);

select throws_ok(
  $$ select public.finish_request((select rid from tr)) $$,
  'P0001', 'not_owner',
  'a receiver cannot finish their own request - only the provider can'
);

select throws_ok(
  $$ select public.restore_request((select rid from tr), 'back') $$,
  'P0001', 'not_owner',
  'a receiver cannot restore - restore is a provider action'
);

-- A cancelled request is archived, so the provider can bring it back.
set local request.jwt.claims = '{"sub":"e3000000-0000-0000-0000-000000000001"}';
select is(
  (select count(*)::int from public.provider_archive where id = (select rid from tr)),
  1,
  'a cancelled request lands in the provider archive'
);
select is(
  (public.restore_request((select rid from tr), 'back')).status::text,
  'queued',
  'the provider can restore a request the receiver cancelled'
);

-- Closing shop.
select public.set_provider_active((select pid from t), false);

select is(
  (select count(*)::int from public.provider_public where id = (select pid from t)),
  0,
  'an inactive provider disappears from discovery'
);

set local request.jwt.claims = '{"sub":"e3000000-0000-0000-0000-000000000002"}';
select throws_ok(
  $$ select public.create_request((select pid from t), '[]'::jsonb, null, 'rcv-k2') $$,
  'P0001', 'provider_inactive',
  'an inactive provider refuses new requests'
);

select * from finish();
rollback;
