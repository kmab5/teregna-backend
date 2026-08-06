#!/usr/bin/env bash
# Run the pgTAP suite against the local database.
set -euo pipefail
cd "$(dirname "$0")/.."
supabase test db
