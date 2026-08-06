#!/usr/bin/env node
// One-time local setup: start the stack, apply migrations and seed.
//
//   npm run bootstrap
import { ok, requireDocker, sb, step } from "./lib.mjs";

step("Checking for a Docker-compatible runtime");
requireDocker();
ok("runtime is up");

step("Starting the local Supabase stack (first run downloads images - be patient)");
sb(["start"]);

step("Applying migrations and seed data");
sb(["db", "reset"]);

step("Local stack");
sb(["status"]);

console.log(`
Studio:  http://localhost:54323

Seeded logins - password: teregna123

  abebe@teregna.test   provider - Abebe Barbershop, active, live queue of 3
  meron@teregna.test   provider - two shops, one closed
  sara@teregna.test    receiver - active and past requests
  dawit@teregna.test   receiver

Next:  npm run types      generate types/database.types.ts
       npm run verify     run everything CI runs
`);
