# Teregna — Backend

ተረኛ · *the one whose turn it is*

The Supabase backend for Teregna: Postgres schema, row-level security, the RPC
surface, realtime configuration, storage policies, and Edge Functions. Every
client — web, Android, iOS — talks to this and nothing else.

Product and architecture documentation lives in the separate `teregna-docs`
set. This repo is the implementation.

---

## The one rule

**All request writes go through RPC. Clients hold no `INSERT`/`UPDATE`/`DELETE`
grant on `requests`.**

Queue order, status transitions, and tenancy are enforced in the database, so a
bug in any client cannot corrupt a queue or leak another provider's data. Reads
go through RLS-protected tables and views; writes go through `security definer`
functions that lock the row, re-check ownership, and validate the transition.

---

## Quick start

Requires [Docker](https://docs.docker.com/get-docker/) and the
[Supabase CLI](https://supabase.com/docs/guides/local-development).

```bash
git clone <this-repo> && cd teregna-backend
./scripts/bootstrap.sh
```

That starts local Supabase, applies every migration, and loads sample data.
Studio runs at <http://localhost:54323>.

Seeded logins — password `teregna123`:

| Email | Role |
|-------|------|
| `abebe@teregna.test` | Provider — Abebe Barbershop, active, live queue of 3 |
| `meron@teregna.test` | Provider — two shops, one closed |
| `sara@teregna.test`  | Receiver — active and past requests |
| `dawit@teregna.test` | Receiver |

Before opening a PR:

```bash
./scripts/verify.sh    # reset + tests + lint + drift check + function lint
```

---

## Repository layout

```
supabase/
├── config.toml              # project config, storage buckets, edge functions
├── seed.sql                 # local + preview branch sample data (never production)
├── migrations/              # ordered, append-only schema history
├── functions/               # Deno Edge Functions
└── tests/database/          # pgTAP suite (72 assertions)
.github/workflows/           # CI + Supabase preview-branch status gate
scripts/                     # bootstrap, reset, test, gen-types, verify
types/database.types.ts      # generated; CI fails if stale
docs/                        # conventions, error codes, runbook
```

`supabase/` sits at the repository root, so the **working directory** in the
Supabase GitHub integration is `.`.

---

## Domain model

```
profiles ──1:N──> providers ──1:N──> items
                      │
                      └──1:N──> requests ──1:N──> request_items
                                    ▲
profiles ───────────1:N─────────────┘  (receiver)
```

| Table | Purpose |
|-------|---------|
| `profiles` | One row per auth user, created automatically by trigger |
| `providers` | Owning a row here *is* being a provider — there is no role column |
| `items` | What a provider offers; `is_visible` toggles receiver visibility |
| `requests` | The queue. Ordered by `seq`; position is derived, never stored |
| `request_items` | Line items with **snapshotted** name and price |

Status: `queued → in_progress → completed | cancelled`, and
`completed | cancelled → queued` via restore.
Active queue = `queued + in_progress` ordered by `seq` ascending.
Archive = `completed + cancelled`.

Two invariants worth stating plainly:

- **Position is derived.** It is computed with a window function at read time.
  Nothing stores it, so nothing can disagree about it.
- **Line items are snapshots.** Editing or deleting an item never rewrites the
  history of a request that already referenced it.

---

## API surface

### Reads (RLS-protected)

| Object | Who can read | Contents |
|--------|--------------|----------|
| `provider_public` | anyone, guests included | Active providers + queue **count** |
| `items` | anyone | Visible items of active providers |
| `provider_queue` | owning provider | Live queue, ordered, with derived `position` |
| `provider_archive` | owning provider | Completed and cancelled |
| `my_requests` | the receiver | Own requests with true live `position` |

### Writes (RPC only)

| Function | Caller | Notes |
|----------|--------|-------|
| `create_request(provider_id, items, note, idempotency_key)` | receiver | Idempotent; capped at 3 open per provider |
| `start_request(id)` | provider | `queued → in_progress` |
| `finish_request(id)` | provider | Completes and archives |
| `cancel_request(id)` | either party | While active |
| `restore_request(id, mode)` | provider | `'back'` (default) or `'original'` |
| `upsert_provider`, `set_provider_active` | owner | |
| `upsert_item`, `set_item_visible`, `reorder_items`, `delete_item` | owner | |
| `upsert_profile`, `my_provider` | self | |
| `provider_analytics(provider_id, start, end)` | owner | Whole dashboard in one call |

Error codes: `unauthenticated`, `not_owner`, `provider_inactive`,
`invalid_transition`, `not_archived`, `too_many_open_requests`,
`duplicate_request`, `invalid_item`, `invalid_mode`, `invalid_range`.
See [`docs/error-codes.md`](docs/error-codes.md).

---

## Supabase GitHub integration

This repo is designed to be connected directly to Supabase.

**Setup:** Dashboard → Project Settings → Integrations → Authorize GitHub →
select this repo → **Working directory: `.`** → enable *Automatic branching* and
*Deploy to production*.

What deploys on merge to the production branch:

- new migrations in `supabase/migrations`
- Edge Functions declared under `[functions.*]` in `config.toml`
- Storage buckets declared under `[storage.buckets.*]` in `config.toml`

What does **not**: `seed.sql`, and API/Auth settings. Production auth is
configured in the dashboard. No production data is ever copied to a preview
branch.

**Required check.** In branch protection, mark **Supabase Preview** as a
required status check. This is the thing that stops a broken migration reaching
production; `.github/workflows/notify-branch-failure.yml` surfaces the failure
on the PR.

Per-environment overrides go in the commented `[remotes.*]` blocks in
`config.toml` once the branch project refs exist.

---

## Migrations

Append-only. Never edit a migration that has been merged — write a new one.

```bash
./scripts/new-migration.sh add_provider_hours
# edit the generated file
./scripts/verify.sh
```

Guard DDL with `if not exists` / `drop ... if exists` so reruns are safe. CI
rebuilds the database from zero on every PR, so a migration that only works
against an already-migrated database will fail there.

After any schema change, run `./scripts/gen-types.sh` and commit
`types/database.types.ts` — CI fails if it is stale — then mirror the change in
the Kotlin and Swift models.

---

## Testing

`supabase/tests/database/` holds a pgTAP suite of 72 assertions:

| File | Covers |
|------|--------|
| `00_schema.test.sql` | Structure, enum values, RLS enabled, no stored `position`, every definer function pins `search_path`, clients hold no write grant on `requests` |
| `01_queue_lifecycle.test.sql` | The full loop, ordering, idempotency, the open-request cap, restore |
| `02_rls_isolation.test.sql` | A rival provider sees and can do nothing |
| `03_receiver_rights.test.sql` | Receiver cancel rights, inactive-provider handling |

```bash
./scripts/test.sh
```

Isolation failures block release. That is a hard requirement, not a preference.

---

## Security posture

- RLS on every table holding per-user data; policies trace to `auth.uid()`.
- No write policy on `requests` at all — absence of a permissive policy is the
  denial.
- Every `security definer` function pins `search_path` and re-checks ownership.
  A test enforces the first half of that mechanically.
- `service_role` never ships to a client. `analytics-export` deliberately
  forwards the **caller's** JWT rather than using it.
- Storage writes are confined to `<bucket>/<user_id>/…` by policy.
- Default privileges revoke access to future objects, so a new table is closed
  until someone opens it on purpose.

---

## Further reading

- [`docs/conventions.md`](docs/conventions.md) — SQL and migration conventions
- [`docs/error-codes.md`](docs/error-codes.md) — the shared error model
- [`docs/runbook.md`](docs/runbook.md) — deploys, rollbacks, incident steps
