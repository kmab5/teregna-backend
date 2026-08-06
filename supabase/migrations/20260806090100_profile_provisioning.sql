-- =============================================================================
-- 20260806090100_profile_provisioning
-- Auto-create a profiles row for every new auth user, and anonymise on delete.
-- =============================================================================

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, display_name, avatar_url, phone)
  values (
    new.id,
    coalesce(
      nullif(btrim(new.raw_user_meta_data ->> 'display_name'), ''),
      nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
      nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
      'User'
    ),
    new.raw_user_meta_data ->> 'avatar_url',
    new.phone
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- -----------------------------------------------------------------------------
-- Account deletion is an anonymisation, not a destruction.
-- A provider's history must survive a receiver deleting their account.
-- -----------------------------------------------------------------------------
create or replace function public.anonymize_profile(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.profiles
     set display_name = 'Deleted user',
         avatar_url   = null,
         phone        = null
   where id = p_user_id;

  -- Owned providers go dark but their request history is retained.
  update public.providers
     set is_active = false
   where owner_id = p_user_id;
end;
$$;

revoke all on function public.anonymize_profile(uuid) from public, anon, authenticated;
