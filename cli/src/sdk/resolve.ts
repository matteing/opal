import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { resolve, join } from "node:path";
import { platform, homedir } from "node:os";
import { fileURLToPath } from "node:url";

export interface ServerResolution {
  /** Command to spawn (binary path or executable name) */
  command: string;
  /** Arguments to pass to the command */
  args: string[];
  /** Working directory for the spawned process */
  cwd?: string;
}

/**
 * Detect if we're running from the Opal monorepo source tree.
 * If so, use `mise exec` to launch the server with the correct tool versions.
 */
function detectMonorepo(): ServerResolution | null {
  try {
    const thisFile = fileURLToPath(import.meta.url);
    // cli/{src,dist}/sdk/resolve.{ts,js} → repo root is 4 levels up
    const repoRoot = resolve(thisFile, "../../../..");

    if (
      existsSync(join(repoRoot, "opal", "mix.exs")) &&
      existsSync(join(repoRoot, "opal", "lib", "opal"))
    ) {
      return {
        command: "mise",
        args: ["exec", "--", "elixir", "-S", "mix", "run", "--no-halt"],
        cwd: join(repoRoot, "opal"),
      };
    }
  } catch {
    // not in monorepo
  }
  return null;
}

/** Read the package version to locate the extracted release. */
function getPackageVersion(): string {
  const pkgPath = resolve(fileURLToPath(import.meta.url), "../../../package.json");
  const pkg = JSON.parse(readFileSync(pkgPath, "utf-8"));
  return pkg.version;
}

/**
 * Resolve the opal-server binary.
 *
 * 0. Monorepo dev mode via `mise exec` (when running from source tree)
 * 1. `opal-server` in PATH (user-installed or dev build)
 * 2. Extracted OTP release at ~/.opal/erts/<version>/
 */
export function resolveServer(): ServerResolution {
  // 0. Monorepo dev mode
  const monorepo = detectMonorepo();
  if (monorepo) return monorepo;

  // 1. Check PATH
  try {
    const cmd = process.platform === "win32" ? "where" : "which";
    const found = execFileSync(cmd, ["opal-server"], {
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
    if (found && existsSync(found)) {
      return { command: found, args: [] };
    }
  } catch {
    // not in PATH
  }

  // 2. Extracted OTP release at ~/.opal/erts/<version>/
  const version = getPackageVersion();
  const releaseDir = join(homedir(), ".opal", "erts", version);
  const binName = platform() === "win32" ? "opal_server.bat" : "opal_server";
  const binPath = join(releaseDir, "bin", binName);

  if (existsSync(binPath)) {
    return { command: binPath, args: ["start"] };
  }

  throw new Error(
    [
      `opal-server not found.`,
      ``,
      `Tried:`,
      `  1. opal-server in PATH`,
      `  2. ${binPath}`,
      ``,
      `Run "npm rebuild @unfinite/opal" to extract the server, or install opal-server manually.`,
    ].join("\n"),
  );
}
