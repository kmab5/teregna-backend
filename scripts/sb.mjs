#!/usr/bin/env node
// Thin pass-through to the Supabase CLI, so every npm script goes through the
// same resolution logic (local dev dependency, no global install needed).
//
//   npm run start        -> supabase start
//   npm run status       -> supabase status
//   node scripts/sb.mjs db push --linked
import { sb } from "./lib.mjs";

const args = process.argv.slice(2);
if (args.length === 0) {
  console.error("usage: node scripts/sb.mjs <supabase args...>");
  process.exit(1);
}
sb(args);
