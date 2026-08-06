#!/usr/bin/env node
// Deploy this repo to a HOSTED Supabase project from your machine.
//
//   npm run deploy -- --project-ref abcdefghijklmnop
//
// Use this when the GitHub integration has not deployed for you, or for the
// very first deploy of a fresh project. It does what the integration does:
//
//   1. links this directory to the project
//   2. applies every migration in supabase/migrations
//   3. deploys the Edge Functions declared in config.toml
//
// It deliberately does NOT run seed.sql. Seed data is for local and preview
// environments only - never production.
import { ok, sb, step, warn } from "./lib.mjs";

const args = process.argv.slice(2);
const refIndex = args.findIndex((a) => a === "--project-ref" || a === "-p");
const projectRef = refIndex >= 0 ? args[refIndex + 1] : process.env.SUPABASE_PROJECT_REF;
const skipFunctions = args.includes("--skip-functions");

if (!projectRef) {
  console.error(`
usage: npm run deploy -- --project-ref <ref>

Find <ref> in your Supabase dashboard URL:
  https://supabase.com/dashboard/project/<ref>

You will be asked for the database password (Project Settings > Database).
`);
  process.exit(1);
}

step(`Linking to project ${projectRef}`);
// Already-linked is not an error worth stopping for.
const link = sb(["link", "--project-ref", projectRef], { allowFailure: true });
if (link.status !== 0) {
  warn("link reported a problem - continuing in case the project is already linked");
} else {
  ok("linked");
}

step("Applying migrations to the remote database");
sb(["db", "push"]);
ok("migrations applied");

if (!skipFunctions) {
  step("Deploying Edge Functions");
  const fn = sb(["functions", "deploy"], { allowFailure: true });
  if (fn.status !== 0) {
    warn("function deploy failed - migrations are still applied");
    warn("retry with: npx supabase functions deploy analytics-export");
  } else {
    ok("functions deployed");
  }
}

console.log(`
Done. Verify in the dashboard SQL editor:

  select table_name from information_schema.tables
   where table_schema = 'public' order by table_name;

Expect: items, profiles, providers, request_items, requests
(plus the views: my_requests, provider_archive, provider_public, provider_queue)

The tables will be EMPTY. seed.sql is never applied to production - that is
intentional, not a failure.
`);
