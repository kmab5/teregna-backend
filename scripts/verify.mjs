#!/usr/bin/env node
// Everything CI runs, locally. Use this before opening a PR.
//
//   npm run verify
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import {
  colors,
  fail,
  ok,
  repoRoot,
  requireDocker,
  run,
  sb,
  step,
  warn,
} from "./lib.mjs";

requireDocker();

let failures = 0;
function record(name) {
  failures += 1;
  fail(name);
}

// ---------------------------------------------------------------- migrations
step("Rebuilding the database from migrations");
sb(["db", "reset"]);
ok("every migration applied from scratch");

// --------------------------------------------------------------------- tests
step("Running pgTAP tests");
sb(["test", "db"]);
ok("all assertions passed");

// ---------------------------------------------------------------------- lint
step("Linting the schema");
const lint = sb(["db", "lint", "--level", "warning"], { allowFailure: true });
if (lint.status === 0) ok("no lint warnings");
else record("schema lint reported problems");

// --------------------------------------------------------------------- drift
// The checked-in migrations must fully describe the database. Any output here
// means someone changed the database without writing a migration.
step("Checking for schema drift");
const drift = sb(["db", "diff", "--schema", "public"], {
  capture: true,
  allowFailure: true,
});
const driftText = drift.stdout.trim();
if (!driftText || /no schema changes found/i.test(driftText)) {
  ok("no drift - migrations describe the database");
} else {
  record("schema drift detected - a change was made without a migration");
  console.log(`${colors.dim}${driftText}${colors.reset}`);
}

// --------------------------------------------------------------------- types
step("Checking generated types are current");
const typesPath = join(repoRoot, "types", "database.types.ts");
const generated = sb(
  ["gen", "types", "typescript", "--local", "--schema", "public"],
  { capture: true, allowFailure: true },
);
if (!existsSync(typesPath)) {
  record("types/database.types.ts is missing - run `npm run types`");
} else if (
  generated.stdout.trim() !== readFileSync(typesPath, "utf8").trim()
) {
  record("types/database.types.ts is stale - run `npm run types` and commit");
} else {
  ok("types match the schema");
}

// ------------------------------------------------------------ edge functions
step("Checking Edge Functions");
const denoVersion = run("deno", ["--version"], {
  allowFailure: true,
  capture: true,
});
if (denoVersion.status !== 0) {
  warn("Deno not installed - skipping function format, lint and type check");
  warn("install from https://docs.deno.com/runtime/getting_started/installation/");
} else {
  const fmt = run("deno", ["fmt", "--check", "supabase/functions"], {
    allowFailure: true,
  });
  fmt.status === 0 ? ok("formatting") : record("deno fmt found problems");

  const lintFn = run("deno", ["lint", "supabase/functions"], {
    allowFailure: true,
  });
  lintFn.status === 0 ? ok("lint") : record("deno lint found problems");
}

// -------------------------------------------------------------------- result
console.log("");
if (failures > 0) {
  fail(`${failures} check(s) failed.`);
  process.exit(1);
}
console.log(`${colors.green}All checks passed.${colors.reset}`);
