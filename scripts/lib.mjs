// Shared helpers for the Node scripts.
// Cross-platform: works on Windows, macOS and Linux with no bash and no
// globally installed Supabase CLI. The CLI comes from devDependencies.

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const isWindows = process.platform === "win32";

export const colors = {
  reset: "\x1b[0m",
  dim: "\x1b[2m",
  red: "\x1b[31m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  cyan: "\x1b[36m",
};

export function step(message) {
  console.log(`\n${colors.cyan}==>${colors.reset} ${message}`);
}
export function ok(message) {
  console.log(`${colors.green}  OK${colors.reset} ${message}`);
}
export function warn(message) {
  console.log(`${colors.yellow}  !${colors.reset}  ${message}`);
}
export function fail(message) {
  console.error(`${colors.red}  ERROR${colors.reset} ${message}`);
}

/**
 * Locate the Supabase CLI binary installed by `npm install`.
 * Falls back to a globally installed `supabase` if someone has one.
 */
function resolveCli() {
  const localBin = join(
    repoRoot,
    "node_modules",
    ".bin",
    isWindows ? "supabase.cmd" : "supabase",
  );
  if (existsSync(localBin)) return localBin;
  return isWindows ? "supabase.cmd" : "supabase";
}

/**
 * Run the Supabase CLI. Output streams straight to the terminal.
 * Returns the exit status rather than throwing, so callers decide what a
 * non-zero exit means.
 */
export function sb(args, { capture = false, allowFailure = false } = {}) {
  const cli = resolveCli();
  const result = spawnSync(cli, args, {
    cwd: repoRoot,
    stdio: capture ? ["inherit", "pipe", "pipe"] : "inherit",
    encoding: "utf8",
    // Needed on Windows so a .cmd shim is executed correctly.
    shell: isWindows,
  });

  if (result.error) {
    if (result.error.code === "ENOENT") {
      fail(
        "Supabase CLI not found. Run `npm install` first - the CLI is a dev dependency of this repo.",
      );
      process.exit(1);
    }
    throw result.error;
  }

  if (result.status !== 0 && !allowFailure) {
    fail(`\`supabase ${args.join(" ")}\` exited with code ${result.status}`);
    if (capture && result.stderr) console.error(result.stderr);
    process.exit(result.status ?? 1);
  }

  return {
    status: result.status,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
  };
}

/** Run any other command (deno, git). Same conventions as sb(). */
export function run(command, args, { allowFailure = false, capture = false } = {}) {
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    stdio: capture ? ["inherit", "pipe", "pipe"] : "inherit",
    encoding: "utf8",
    shell: isWindows,
  });

  if (result.error && result.error.code === "ENOENT") {
    return { status: 127, stdout: "", stderr: "not_found" };
  }
  if (result.status !== 0 && !allowFailure) {
    fail(`\`${command} ${args.join(" ")}\` exited with code ${result.status}`);
    process.exit(result.status ?? 1);
  }
  return {
    status: result.status,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
  };
}

/** Is a Docker-compatible runtime up? The local stack needs one. */
export function dockerRunning() {
  const result = spawnSync("docker", ["info"], {
    stdio: "ignore",
    shell: isWindows,
  });
  return result.status === 0;
}

export function requireDocker() {
  if (dockerRunning()) return;
  fail("No running Docker-compatible runtime found.");
  console.error(`
The local Supabase stack needs Docker Desktop, Rancher Desktop or Podman.

  Docker Desktop:   https://docs.docker.com/get-docker/

If you would rather not run anything locally, you can skip local development
entirely and work against a Supabase branch instead - see "Working without
Docker" in README.md.
`);
  process.exit(1);
}
