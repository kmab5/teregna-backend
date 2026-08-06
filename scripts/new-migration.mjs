#!/usr/bin/env node
// Create a timestamped migration file.
//
//   npm run migration:new -- add_provider_hours
import { sb, warn } from "./lib.mjs";

const name = process.argv[2];

if (!name) {
  console.error("usage: npm run migration:new -- <snake_case_name>");
  process.exit(1);
}
if (!/^[a-z0-9]+(_[a-z0-9]+)*$/.test(name)) {
  console.error(`Invalid name "${name}". Use lower_snake_case, e.g. add_provider_hours`);
  process.exit(1);
}

sb(["migration", "new", name]);

console.log("\nBefore you commit:");
warn("migrations are append-only - never edit one that has been merged");
warn("guard DDL with `if not exists` / `drop ... if exists` so reruns are safe");
warn("add or update a pgTAP test in supabase/tests/database/");
warn("run `npm run verify`");
