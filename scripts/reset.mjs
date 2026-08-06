#!/usr/bin/env node
// Rebuild the local database from scratch: every migration, then seed.sql.
// Run this after pulling new migrations.
//
//   npm run reset
import { ok, requireDocker, sb, step } from "./lib.mjs";

requireDocker();
step("Rebuilding the database from migrations");
sb(["db", "reset"]);
ok("migrations and seed applied");
