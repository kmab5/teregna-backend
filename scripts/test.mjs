#!/usr/bin/env node
// Run the pgTAP suite against the local database.
//
//   npm test
//
// The suite runs AFTER seed.sql, so tests are written to be seed-independent.
// If you add one, scope every count to the fixtures that test creates.
import { ok, requireDocker, sb, step } from "./lib.mjs";

requireDocker();
step("Running pgTAP tests");
sb(["test", "db"]);
ok("all assertions passed");
