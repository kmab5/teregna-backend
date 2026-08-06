#!/usr/bin/env bash
# One-time local setup. Requires Docker and the Supabase CLI.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v supabase >/dev/null 2>&1 || {
  echo "Supabase CLI not found. Install: https://supabase.com/docs/guides/local-development"
  exit 1
}
docker info >/dev/null 2>&1 || { echo "Docker is not running."; exit 1; }

echo "Starting local Supabase..."
supabase start

echo
echo "Applying migrations and seed..."
supabase db reset

echo
supabase status
echo
echo "Seeded logins (password: teregna123)"
echo "  abebe@teregna.test  - provider, Abebe Barbershop (active, live queue)"
echo "  meron@teregna.test  - provider, 2 shops (one closed)"
echo "  sara@teregna.test   - receiver, has active + past requests"
echo "  dawit@teregna.test  - receiver"
