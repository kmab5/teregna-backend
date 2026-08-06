-- =============================================================================
-- seed.sql — sample data for LOCAL development and PREVIEW branches only.
--
-- The GitHub integration never runs this against production, and no production
-- data is ever copied into a preview branch.
--
-- Logins: every seeded user has the password  teregna123
-- =============================================================================

-- ---------------------------------------------------------------- auth users
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
values
  ('00000000-0000-0000-0000-000000000000',
   '11111111-1111-1111-1111-111111111111', 'authenticated', 'authenticated',
   'abebe@teregna.test', crypt('teregna123', gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}',
   '{"display_name":"Abebe Kebede"}', now(), now()),

  ('00000000-0000-0000-0000-000000000000',
   '22222222-2222-2222-2222-222222222222', 'authenticated', 'authenticated',
   'meron@teregna.test', crypt('teregna123', gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}',
   '{"display_name":"Meron Tesfaye"}', now(), now()),

  ('00000000-0000-0000-0000-000000000000',
   '33333333-3333-3333-3333-333333333333', 'authenticated', 'authenticated',
   'sara@teregna.test', crypt('teregna123', gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}',
   '{"display_name":"Sara Girma"}', now(), now()),

  ('00000000-0000-0000-0000-000000000000',
   '44444444-4444-4444-4444-444444444444', 'authenticated', 'authenticated',
   'dawit@teregna.test', crypt('teregna123', gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}',
   '{"display_name":"Dawit Alemu"}', now(), now())
on conflict (id) do nothing;

-- Identities are required for email/password sign-in to work.
insert into auth.identities (
  id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at
)
select
  gen_random_uuid(), u.id, u.id::text,
  jsonb_build_object('sub', u.id::text, 'email', u.email),
  'email', now(), now(), now()
from auth.users u
where u.email like '%@teregna.test'
on conflict do nothing;

-- Profiles are created by the on_auth_user_created trigger. Enrich them.
update public.profiles set locale = 'am'
 where id in ('11111111-1111-1111-1111-111111111111',
              '33333333-3333-3333-3333-333333333333');

-- ---------------------------------------------------------------- providers
insert into public.providers (id, owner_id, name, description, category, location, lat, lng, is_active)
values
  ('aaaaaaaa-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111',
   'Abebe Barbershop',
   'Classic cuts and hot-towel shaves. Walk-ins welcome.',
   'barber', 'Bole, Addis Ababa', 8.993900, 38.789600, true),

  ('aaaaaaaa-0000-0000-0000-000000000002',
   '22222222-2222-2222-2222-222222222222',
   'Meron Tailoring',
   'Custom habesha kemis, alterations, and repairs.',
   'tailor', 'Piassa, Addis Ababa', 9.034300, 38.752300, true),

  ('aaaaaaaa-0000-0000-0000-000000000003',
   '22222222-2222-2222-2222-222222222222',
   'Meron Dry Cleaning',
   'Second shop, currently closed.',
   'laundry', 'Kazanchis, Addis Ababa', 9.013000, 38.775000, false)
on conflict (id) do nothing;

-- -------------------------------------------------------------------- items
insert into public.items (id, provider_id, name, description, price, is_visible, display_order)
values
  ('bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001',
   'Haircut', 'Standard cut and style', 150.00, true, 1),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001',
   'Beard Trim', 'Shape and line-up', 80.00, true, 2),
  ('bbbbbbbb-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000001',
   'Hot Towel Shave', 'Full traditional shave', 200.00, true, 3),
  -- Hidden: exercises the visibility toggle. Receivers must NOT see this.
  ('bbbbbbbb-0000-0000-0000-000000000004', 'aaaaaaaa-0000-0000-0000-000000000001',
   'Weekend Special', 'Not offered right now', 300.00, false, 4),

  ('bbbbbbbb-0000-0000-0000-000000000005', 'aaaaaaaa-0000-0000-0000-000000000002',
   'Habesha Kemis (custom)', 'Made to measure', 3500.00, true, 1),
  ('bbbbbbbb-0000-0000-0000-000000000006', 'aaaaaaaa-0000-0000-0000-000000000002',
   'Trouser Hemming', 'Same-day where possible', 120.00, true, 2)
on conflict (id) do nothing;

-- ----------------------------------------------------------------- requests
-- Written directly (not via RPC) because the seed runs without a JWT.
-- Mix of live queue and archive so every screen has something to render.
insert into public.requests
  (id, provider_id, receiver_id, status, seq, note, created_at, started_at, completed_at, cancelled_at)
values
  -- Live queue for Abebe Barbershop
  ('cccccccc-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001',
   '33333333-3333-3333-3333-333333333333', 'in_progress', 1001,
   'In a bit of a hurry', now() - interval '25 minutes', now() - interval '5 minutes', null, null),

  ('cccccccc-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001',
   '44444444-4444-4444-4444-444444444444', 'queued', 1002,
   null, now() - interval '18 minutes', null, null, null),

  ('cccccccc-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000001',
   '22222222-2222-2222-2222-222222222222', 'queued', 1003,
   'Beard only please', now() - interval '6 minutes', null, null, null),

  -- Archive for Abebe Barbershop
  ('cccccccc-0000-0000-0000-000000000004', 'aaaaaaaa-0000-0000-0000-000000000001',
   '33333333-3333-3333-3333-333333333333', 'completed', 990,
   null, now() - interval '2 days', now() - interval '2 days' + interval '10 min',
   now() - interval '2 days' + interval '35 min', null),

  ('cccccccc-0000-0000-0000-000000000005', 'aaaaaaaa-0000-0000-0000-000000000001',
   '44444444-4444-4444-4444-444444444444', 'cancelled', 991,
   'Changed my mind', now() - interval '1 day', null, null, now() - interval '1 day' + interval '4 min'),

  ('cccccccc-0000-0000-0000-000000000006', 'aaaaaaaa-0000-0000-0000-000000000001',
   '33333333-3333-3333-3333-333333333333', 'completed', 992,
   null, now() - interval '5 hours', now() - interval '5 hours' + interval '3 min',
   now() - interval '5 hours' + interval '28 min', null),

  -- Meron Tailoring
  ('cccccccc-0000-0000-0000-000000000007', 'aaaaaaaa-0000-0000-0000-000000000002',
   '33333333-3333-3333-3333-333333333333', 'queued', 1004,
   'For a wedding on the 20th', now() - interval '40 minutes', null, null, null)
on conflict (id) do nothing;

-- Keep the sequence ahead of the hand-written seq values.
select setval('public.request_seq', 2000, true);

-- ------------------------------------------------------------ request items
insert into public.request_items
  (request_id, item_id, item_name_snapshot, item_price_snapshot, quantity)
values
  ('cccccccc-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001', 'Haircut', 150.00, 1),
  ('cccccccc-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000002', 'Beard Trim', 80.00, 1),
  ('cccccccc-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000003', 'Hot Towel Shave', 200.00, 1),
  ('cccccccc-0000-0000-0000-000000000003', 'bbbbbbbb-0000-0000-0000-000000000002', 'Beard Trim', 80.00, 1),
  ('cccccccc-0000-0000-0000-000000000004', 'bbbbbbbb-0000-0000-0000-000000000001', 'Haircut', 150.00, 1),
  ('cccccccc-0000-0000-0000-000000000005', 'bbbbbbbb-0000-0000-0000-000000000001', 'Haircut', 150.00, 1),
  ('cccccccc-0000-0000-0000-000000000006', 'bbbbbbbb-0000-0000-0000-000000000001', 'Haircut', 150.00, 2),
  -- Snapshot with a NULL item_id: proves history survives item deletion.
  ('cccccccc-0000-0000-0000-000000000006', null, 'Discontinued Treatment', 90.00, 1),
  ('cccccccc-0000-0000-0000-000000000007', 'bbbbbbbb-0000-0000-0000-000000000005', 'Habesha Kemis (custom)', 3500.00, 1)
on conflict do nothing;
