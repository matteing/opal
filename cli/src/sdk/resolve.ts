import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { resolve, join } from "node:path";
import { platform, arch } from "node:os";
import { fileURLToPath } from "node:url";

const PLATFORM_MAP: Record<string, string> = {
  "darwin-arm64": "opal-server-darwin-arm64",
  "darwin-x64": "opal-server-darwin-x64",
  "linux-x64": "opal-server-linux-x64",
  "linux-arm64": "opal-server-linux-arm64",
};

export interface ServerResolution {
  /** Command to spawn (binary path, or "mix"/"elixir") */
  command: string;
  /** Arguments to pass to the command */
  args: string[];
  /** Working directory to spawn in (for dev mode) */
  cwd?: string;
}

/**
 * Resolve the opal-server binary or dev command.
 *
 * 1. `opal-server` in PATH (user-installed)
 * 2. Bundled binary in `releases/` (npm distribution)
 * 3. Monorepo dev mode: `elixir --erl "-noinput" -S mix run --no-halt` in `core/`
 */
export function resolveServer(): ServerResolution {
  // 1. Check PATH
  try {
    const found = execFileSync("which", ["opal-server"], {
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

  // 3. Monorepo dev mode — look for ../core/mix.exs relative to package root
  const pkgRoot = resolve(fileURLToPath(import.meta.url), "../../..");
  const coreDir = resolve(pkgRoot, "../core");
  const coreMix = join(coreDir, "mix.exs");
  if (existsSync(coreMix)) {
    return {
      command: "elixir",
      args: ["--sname", "opal", "--cookie", "opal", "--erl", "-noinput", "-S", "mix", "run", "--no-halt"],
      cwd: coreDir,
    };
  }

  const tried = [
    `  1. opal-server in PATH`,
    name ? `  2. ${join(resolve(fileURLToPath(import.meta.url), "../../releases"), name)}` : `  2. (unsupported platform: ${key})`,
    `  3. ${coreMix} (monorepo dev mode)`,
  ];

  throw new Error(
    [`opal-server not found.`, ``, `Tried:`, ...tried, ``, `Install opal-server or place a binary in the releases/ directory.`].join("\n"),
  );
}
