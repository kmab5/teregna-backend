#!/usr/bin/env node
// Regenerate TypeScript types from the local schema.
//
//   npm run types
//
// Commit the result. CI fails if it is stale, which is what keeps the web
// client's types honest against the real schema.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { ok, repoRoot, requireDocker, sb, step } from "./lib.mjs";

requireDocker();
step("Generating types from the local schema");

const { stdout } = sb(
  ["gen", "types", "typescript", "--local", "--schema", "public"],
  { capture: true },
);

if (!stdout.trim()) {
  console.error("The CLI returned nothing. Is the local stack running? Try `npm run start`.");
  process.exit(1);
}

mkdirSync(join(repoRoot, "types"), { recursive: true });
writeFileSync(join(repoRoot, "types", "database.types.ts"), stdout, "utf8");

ok("wrote types/database.types.ts");
console.log(
  "\nCopy this into the web app, and mirror any table/view/RPC change in the\n" +
    "Kotlin and Swift models.",
);
