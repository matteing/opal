import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { resolve, join } from "node:path";
import { platform, arch } from "node:os";
import { fileURLToPath } from "node:url";

const PLATFORM_MAP: Record<string, string> = {
  "darwin-arm64": "opal_server_darwin_arm64",
  "darwin-x64": "opal_server_darwin_x64",
  "linux-x64": "opal_server_linux_x64",
  "linux-arm64": "opal_server_linux_arm64",
  "win32-x64": "opal_server_win32_x64.exe",
};

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

    if (existsSync(join(repoRoot, "mix.exs")) && existsSync(join(repoRoot, "lib", "opal"))) {
      return {
        command: "mise",
        args: ["exec", "--", "elixir", "-S", "mix", "run", "--no-halt"],
        cwd: repoRoot,
      };
    }
  } catch {
    // not in monorepo
  }
  return null;
}

/**
 * Resolve the opal-server binary.
 *
 * 0. Monorepo dev mode via `mise exec` (when running from source tree)
 * 1. `opal-server` in PATH (user-installed or dev build)
 * 2. Bundled platform binary in `releases/` (npm distribution)
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

  // 2. Bundled binary
  const key = `${platform()}-${arch()}`;
  const name = PLATFORM_MAP[key];
  if (name) {
    const dir = resolve(fileURLToPath(import.meta.url), "../../../releases");
    const binPath = join(dir, name);
    if (existsSync(binPath)) {
      return { command: binPath, args: [] };
    }
  }

  const tried = [
    `  1. opal-server in PATH`,
    name
      ? `  2. ${join(resolve(fileURLToPath(import.meta.url), "../../releases"), name)}`
      : `  2. (unsupported platform: ${key})`,
  ];

  throw new Error(
    [
      `opal-server not found.`,
      ``,
      `Tried:`,
      ...tried,
      ``,
      `Install opal-server or place a binary in the releases/ directory.`,
    ].join("\n"),
  );
}
