#!/usr/bin/env node
/**
 * postinstall.js — Extract the platform-specific OTP release tarball
 * to ~/.opal/erts/<version>/ so the CLI can spawn the Elixir server.
 *
 * Skips extraction if the target directory already exists.
 * Ships inside the npm package under releases/.
 */

import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join, resolve } from "node:path";
import { homedir, platform, arch } from "node:os";
import { fileURLToPath } from "node:url";

const PLATFORM_MAP = {
  "darwin-arm64": "opal-server-darwin-arm64.tar.gz",
  "darwin-x64": "opal-server-darwin-x64.tar.gz",
  "linux-x64": "opal-server-linux-x64.tar.gz",
  "linux-arm64": "opal-server-linux-arm64.tar.gz",
  "win32-x64": "opal-server-win32-x64.tar.gz",
};

function main() {
  // Read version from package.json
  const pkgPath = resolve(fileURLToPath(import.meta.url), "../../package.json");
  const pkg = JSON.parse(readFileSync(pkgPath, "utf-8"));
  const version = pkg.version;

  const key = `${platform()}-${arch()}`;
  const tarball = PLATFORM_MAP[key];

  if (!tarball) {
    console.warn(`[opal] Unsupported platform: ${key} — skipping server extraction.`);
    console.warn(`[opal] You can install opal-server manually and place it in your PATH.`);
    process.exit(0);
  }

  const targetDir = join(homedir(), ".opal", "erts", version);

  // Skip if already extracted
  if (existsSync(join(targetDir, "bin"))) {
    console.log(`[opal] Server v${version} already installed at ${targetDir}`);
    process.exit(0);
  }

  // Find the tarball shipped in the npm package
  const releasesDir = resolve(fileURLToPath(import.meta.url), "../../releases");
  const tarballPath = join(releasesDir, tarball);

  if (!existsSync(tarballPath)) {
    // Not an error — this happens in dev/monorepo mode where releases/ isn't populated
    console.log(`[opal] No bundled release found at ${tarballPath} — skipping.`);
    console.log(`[opal] In dev mode, the CLI uses mise to run the server from source.`);
    process.exit(0);
  }

  // Create target directory
  mkdirSync(targetDir, { recursive: true });

  console.log(`[opal] Extracting server v${version} for ${key}...`);

  try {
    if (platform() === "win32") {
      // Use PowerShell's tar (available on Windows 10+)
      execFileSync("tar", ["-xzf", tarballPath, "-C", targetDir], {
        stdio: "inherit",
      });
    } else {
      execFileSync("tar", ["-xzf", tarballPath, "-C", targetDir], {
        stdio: "inherit",
      });
    }
    console.log(`[opal] Server installed to ${targetDir}`);
  } catch (err) {
    console.error(`[opal] Failed to extract release: ${err.message}`);
    // Clean up partial extraction
    try {
      execFileSync("rm", ["-rf", targetDir]);
    } catch {
      // best-effort cleanup
    }
    process.exit(1);
  }
}

main();
