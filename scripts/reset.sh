#!/usr/bin/env bash
# Rebuild the local database from scratch: every migration, then seed.sql.
# Run this after pulling new migrations.
set -euo pipefail
cd "$(dirname "$0")/.."
supabase db reset
echo "Database reset. Migrations + seed applied."
