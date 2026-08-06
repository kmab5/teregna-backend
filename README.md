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

You need **Node.js 20+** and a **Docker-compatible runtime**
([Docker Desktop](https://docs.docker.com/get-docker/), Rancher Desktop, or
Podman). You do **not** need bash, and you do **not** need to install the
Supabase CLI separately — it is pinned as a dev dependency and `npm install`
fetches it.

```
git clone <this-repo>
cd teregna-backend
npm install
npm run bootstrap
```

Every command is a plain Node script, so this works identically in PowerShell,
Command Prompt, Terminal, or any shell.

`npm run bootstrap` starts the local stack, applies every migration, and loads
sample data. Studio runs at <http://localhost:54323>.

Seeded logins — password `teregna123`:

| Email | Role |
|-------|------|
| `abebe@teregna.test` | Provider — Abebe Barbershop, active, live queue of 3 |
| `meron@teregna.test` | Provider — two shops, one closed |
| `sara@teregna.test`  | Receiver — active and past requests |
| `dawit@teregna.test` | Receiver |

### Commands

| Command | What it does |
|---------|--------------|
| `npm run bootstrap` | First-time setup: start the stack, migrate, seed |
| `npm start` / `npm run stop` | Start or stop the local stack |
| `npm run status` | Show local URLs and keys |
| `npm run reset` | Rebuild the database from migrations + seed |
| `npm test` | Run the pgTAP suite |
| `npm run lint` | Lint the schema |
| `npm run types` | Regenerate `types/database.types.ts` |
| `npm run migration:new -- add_provider_hours` | Create a timestamped migration |
| `npm run verify` | **Everything CI runs.** Use before opening a PR |

Anything not wrapped above can be run directly:
`node scripts/sb.mjs <any supabase command>`.

### Working without Docker

Local development needs Docker because the stack runs in containers. If you
can't run it, you can still work entirely through Supabase's hosted
infrastructure:

1. Write your migration by hand into `supabase/migrations/` using the naming
   convention `YYYYMMDDHHMMSS_description.sql`.
2. Push the branch and open a PR. The GitHub integration spins up a **preview
   branch** and applies your migrations there — this is a real Postgres, so a
   broken migration fails visibly on the PR.
3. Inspect the result in the dashboard for that preview branch, and use its SQL
   editor to poke at the schema.
4. Merge when the **Supabase Preview** check is green.

The trade-offs are real: you lose `npm test` (pgTAP runs locally), the drift
check, and type generation — all of which still run in CI, just later in the
loop. Docker gives you a much tighter feedback cycle, so install it when you
can.

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
scripts/                     # cross-platform Node scripts (no bash needed)
package.json                 # pins the Supabase CLI; npm scripts wrap everything
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

```
npm run migration:new -- add_provider_hours
# edit the generated file
npm run verify
```

Guard DDL with `if not exists` / `drop ... if exists` so reruns are safe. CI
rebuilds the database from zero on every PR, so a migration that only works
against an already-migrated database will fail there.

After any schema change, run `npm run types` and commit
`types/database.types.ts` — CI fails if it is stale — then mirror the change in
the Kotlin and Swift models.

---

## Testing

`supabase/tests/database/` holds a pgTAP suite of 79 assertions:

| File | Covers |
|------|--------|
| `00_schema.test.sql` | Structure, enum values, RLS enabled, no stored `position`, clients hold no write grant on `requests`, all views are `security_invoker`, the SECURITY DEFINER list is exactly the expected five (+2 ungranted), nothing definer is anon-executable, every function pins `search_path` |
| `01_queue_lifecycle.test.sql` | The full loop, ordering, idempotency, the open-request cap, restore |
| `02_rls_isolation.test.sql` | A rival provider sees and can do nothing |
| `03_receiver_rights.test.sql` | Receiver cancel rights, inactive-provider handling |

```
npm test
```

Isolation failures block release. That is a hard requirement, not a preference.

---

## Security posture

- RLS on every table holding per-user data; policies trace to `auth.uid()`.
- No write policy on `requests` at all — absence of a permissive policy is the
  denial.
- **All views are `security_invoker`**, so base-table RLS applies on top of each
  view's own filter. The filter is defence in depth, not the whole defence.
- **Only five functions are `SECURITY DEFINER`** — the request-lifecycle RPCs
  that must write to `requests`. Everything else runs as the caller.
- Cross-tenancy helpers live in a **`private` schema that PostgREST does not
  expose**, so they are unreachable over the API.
- Every function pins `search_path` and re-checks ownership. Tests enforce all
  of the above mechanically.
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
