/**
 * Sync the Elixir package version in core/mix.exs to match the Nx release version.
 * Called by Nx Release via postVersionCommand.
 *
 * Usage: node scripts/sync-elixir-version.mjs <version>
 */
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const version = process.argv[2];
if (!version) {
  console.error("Usage: sync-elixir-version.mjs <version>");
  process.exit(1);
}

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const mixPath = resolve(root, "core/mix.exs");
const content = readFileSync(mixPath, "utf-8");
const updated = content.replace(/@version "[^"]+"/, `@version "${version}"`);

if (content === updated) {
  console.log(`mix.exs already at ${version}`);
} else {
  writeFileSync(mixPath, updated);
  console.log(`mix.exs updated to ${version}`);
}
