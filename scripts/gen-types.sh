#!/usr/bin/env bash
# Regenerate TypeScript types from the local schema.
# Run after every schema migration and commit the result: CI fails on drift.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p types
supabase gen types typescript --local --schema public > types/database.types.ts
echo "Wrote types/database.types.ts"
echo "Copy this into the web app and mirror any model changes in the Kotlin and Swift clients."
