-- =============================================================================
-- 20260806090800_storage
-- Buckets are declared in config.toml (that is what the GitHub integration
-- deploys). This migration is the belt-and-braces creation plus the object
-- policies, which config.toml does not cover.
--
-- Path convention — the first folder is always the owning user's id:
--   avatars/<user_id>/<file>
--   provider-covers/<user_id>/<file>
--   item-images/<user_id>/<file>
-- storage.foldername(name)[1] is therefore the owner check.
-- =============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('avatars',         'avatars',         true, 2097152, array['image/png','image/jpeg','image/webp']),
  ('provider-covers', 'provider-covers', true, 5242880, array['image/png','image/jpeg','image/webp']),
  ('item-images',     'item-images',     true, 5242880, array['image/png','image/jpeg','image/webp'])
on conflict (id) do nothing;

-- Public read: these images are shown to receivers browsing anonymously.
drop policy if exists teregna_public_read on storage.objects;
create policy teregna_public_read on storage.objects
  for select to anon, authenticated
  using (bucket_id in ('avatars', 'provider-covers', 'item-images'));

-- Write only inside your own folder.
drop policy if exists teregna_owner_insert on storage.objects;
create policy teregna_owner_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id in ('avatars', 'provider-covers', 'item-images')
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists teregna_owner_update on storage.objects;
create policy teregna_owner_update on storage.objects
  for update to authenticated
  using (
    bucket_id in ('avatars', 'provider-covers', 'item-images')
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id in ('avatars', 'provider-covers', 'item-images')
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists teregna_owner_delete on storage.objects;
create policy teregna_owner_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id in ('avatars', 'provider-covers', 'item-images')
    and (storage.foldername(name))[1] = auth.uid()::text
  );
