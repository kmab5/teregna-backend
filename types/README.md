# Generated types

`database.types.ts` is generated from the schema — do not edit it by hand.

```bash
npm run types
```

Run this after every schema migration and commit the result. CI fails if it is
stale, which is what keeps the web client's types honest.

Android and iOS mirror the same schema by hand. When this file changes in a way
that alters a table, view, or RPC signature, flag it for the mobile clients in
the PR description.
