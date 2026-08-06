# Runbook

## Environments

| Environment | Supabase project | Git branch |
|-------------|------------------|------------|
| Local | Docker via CLI | any |
| Preview | Ephemeral branch, auto-created | any PR branch |
| Staging | Persistent branch | `develop` |
| Production | Main project | `main` |

## Normal deploy

1. Branch from `develop`, write the migration, add a pgTAP test.
2. `./scripts/verify.sh` locally.
3. Open the PR. Supabase creates a preview branch and applies migrations; CI
   runs tests, lint, drift, and type checks.
4. Both **CI** and **Supabase Preview** must be green.
5. Merge to `develop` → staging. Smoke-test.
6. Merge `develop` → `main` → production. Migrations apply, declared Edge
   Functions and storage buckets deploy.

## Smoke test after any production deploy

Run against the live environment with a real account:

- [ ] Discovery lists active providers with correct queue counts
- [ ] A hidden item is not visible to a receiver
- [ ] Send a request → it appears in the provider's queue at the right position
- [ ] Finish it → it leaves the queue and lands in the archive
- [ ] Restore it → it returns to the back of the queue
- [ ] The receiver's live position updated without a manual refresh
- [ ] Analytics loads and the totals move as expected
- [ ] Sign in as a second provider — their queue is empty

## Rollback

**Frontend** rolls back instantly (Vercel promotes a previous deployment).

**Database migrations do not roll back.** Postgres has no undo. Recovery is
forward-only:

1. Write a new migration that reverses the change.
2. Apply through the normal path if the system is functional.
3. For a true emergency, use point-in-time recovery from the dashboard —
   accepting the data loss between the restore point and now.

This asymmetry is why the required Supabase Preview check matters more than any
other gate in this repo.

## Common failures

**Migration failed on the preview branch.** Read the PR comment for the error.
Usually non-idempotent DDL, or a dependency on an object created in the same PR
by a later-timestamped file. Fix and push; the branch redeploys.

**Migration conflict after merge.** Two branches added migrations with
interleaved timestamps and the later one now runs first. Rename the file to a
timestamp after the merged one and re-verify with `supabase db reset`.

**CI reports schema drift.** Someone changed the database through the dashboard
or Studio. Capture it with `supabase db diff --schema public`, turn the output
into a proper migration, and commit it. Do not "fix" drift by editing the
database further.

**Types are stale.** Run `./scripts/gen-types.sh` and commit.

**Realtime stopped updating.** Confirm `requests` is still in the
`supabase_realtime` publication and `replica identity` is `full`:

```sql
select * from pg_publication_tables where pubname = 'supabase_realtime';
select relreplident from pg_class where oid = 'public.requests'::regclass;  -- expect 'f'
```

Clients treat realtime as a notification, not truth — they refetch the
authoritative view on reconnect — so this degrades to "needs refresh" rather
than showing wrong data.

## Incident: suspected data leak between tenants

1. Run the isolation suite against the affected environment immediately:
   `supabase test db` (file `02_rls_isolation.test.sql`).
2. Check whether any view lost its tenancy predicate:
   ```sql
   select definition from pg_views
    where viewname in ('provider_queue','provider_archive','my_requests');
   ```
   Each must still contain its `auth.uid()` predicate.
3. Confirm no client build shipped the service-role key. If one did, rotate the
   key in the dashboard first, then investigate.
4. Confirm RLS is still enabled:
   ```sql
   select relname, relrowsecurity from pg_class
    where oid in ('public.requests'::regclass, 'public.providers'::regclass,
                  'public.items'::regclass, 'public.profiles'::regclass);
   ```

## Key rotation

- `anon` key is public by design; rotating it only forces client updates.
- `service_role` key must be rotated immediately on any suspected exposure. It
  bypasses RLS entirely. It appears in no client bundle in this design — if you
  find it in one, that is the incident.
