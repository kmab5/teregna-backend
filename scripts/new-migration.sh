#!/usr/bin/env bash
# Create a timestamped migration file.
#   ./scripts/new-migration.sh add_provider_hours
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -lt 1 ]; then
  echo "usage: $0 <snake_case_name>"
  exit 1
fi

supabase migration new "$1"
echo
echo "Reminder:"
echo "  - migrations are append-only; never edit one that has been merged"
echo "  - guard DDL with 'if not exists' / 'drop ... if exists' so reruns are safe"
echo "  - add or update a pgTAP test in supabase/tests/database/"
