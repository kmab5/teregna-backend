# Error codes

Every RPC raises a bare code as the exception message with SQLSTATE `P0001`.
Clients match on the code and render a localized string — never the raw
exception.

| Code | Raised by | Meaning | What the client should do |
|------|-----------|---------|---------------------------|
| `unauthenticated` | all mutating RPCs | No JWT, or the session expired | Route to sign-in, preserving context |
| `not_owner` | provider/item/analytics RPCs | Caller does not own the target | Treat as not-found; do not reveal existence |
| `provider_inactive` | `create_request` | Provider closed between browse and submit | "This provider isn't accepting requests right now" |
| `too_many_open_requests` | `create_request` | Receiver already holds 3 open with this provider | Point them at their existing requests |
| `invalid_item` | `create_request` | An item is hidden, deleted, or belongs to another provider | Refresh the provider page; the menu changed |
| `duplicate_request` | `create_request` | Idempotency-key collision that could not be resolved | Refresh "my requests"; it probably went through |
| `invalid_transition` | `start`/`finish`/`cancel` | The request already moved on | Roll back the optimistic update, refetch, explain |
| `not_archived` | `restore_request` | Target is already active | Refetch the archive |
| `invalid_mode` | `restore_request` | Mode was not `back` or `original` | Programming error; fix the call |
| `invalid_range` | `provider_analytics` | `range_end <= range_start` | Programming error; fix the picker |
| `not_found` | `upsert_profile` | Profile row missing | Sign out and back in |

## Two that need care

**`not_owner` is deliberately indistinguishable from not-found.** It is raised
whether the row belongs to someone else or does not exist. Do not write UI copy
that confirms a request exists but belongs to another provider — that is an
enumeration oracle.

**`invalid_transition` is the normal outcome of a race, not a bug.** Two devices
finishing the same request, or a receiver cancelling while the provider taps
finish, both land here. Roll the optimistic update back and say what happened:
"Sara cancelled this request just now."

## Client mapping

```ts
const MESSAGES: Record<string, string> = {
  provider_inactive: t("errors.providerClosed"),
  too_many_open_requests: t("errors.tooManyRequests"),
  invalid_transition: t("errors.alreadyChanged"),
  // ...
};
const message = MESSAGES[err.message?.trim()] ?? t("errors.generic");
```

Anything unrecognised falls back to a generic message and is logged. Never
surface a Postgres error string to a user.

## Adding a code

1. Raise it in the RPC with `using errcode = 'P0001'`.
2. Add a row to this table.
3. Add a `throws_ok` assertion in `supabase/tests/database/`.
4. Add the localized string to every client (en + am).
