#!/usr/bin/env bash
# Everything CI runs, locally. Use before opening a PR.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Rebuilding database from migrations"
supabase db reset

echo "==> pgTAP tests"
supabase test db

echo "==> Schema lint"
supabase db lint --level warning

echo "==> Drift check"
supabase db diff --schema public > /tmp/teregna-drift.sql
if [ -s /tmp/teregna-drift.sql ]; then
  echo "DRIFT DETECTED - a change was made without a migration:"
  cat /tmp/teregna-drift.sql
  exit 1
fi
echo "no drift"

echo "==> Edge Functions"
deno fmt --check supabase/functions
deno lint supabase/functions

echo
echo "All checks passed."
