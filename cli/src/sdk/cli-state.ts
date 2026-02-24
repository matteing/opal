/**
 * File-based CLI state persistence.
 *
 * Reads/writes `<dataDir>/cli_state.json` directly from the CLI process.
 * No RPC round-trip needed — this is a pure CLI concern.
 *
 * @module
 */

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

// ── Types ────────────────────────────────────────────────────────

export interface CliState {
  lastModel: Record<string, unknown> | null;
  preferences: { autoConfirm: boolean; verbose: boolean };
  version: number;
}

interface StoredState {
  last_model?: Record<string, unknown> | null;
  preferences?: Record<string, unknown>;
  [key: string]: unknown;
}

const DEFAULT_PREFERENCES = { autoConfirm: false, verbose: false };
const VERSION = 1;

// ── Data directory ───────────────────────────────────────────────

/** Resolves the Opal data directory (`~/.opal` or `OPAL_DATA_DIR`). */
export function getDataDir(): string {
  return process.env.OPAL_DATA_DIR ?? join(homedir(), ".opal");
}

function statePath(): string {
  return join(getDataDir(), "cli_state.json");
}

// ── Read / Write ─────────────────────────────────────────────────

function readRaw(): StoredState {
  try {
    const data = readFileSync(statePath(), "utf-8");
    const parsed: unknown = JSON.parse(data);
    return typeof parsed === "object" && parsed !== null ? (parsed as StoredState) : {};
  } catch {
    return {};
  }
}

function writeRaw(data: StoredState): void {
  const dir = getDataDir();
  mkdirSync(dir, { recursive: true });
  writeFileSync(statePath(), JSON.stringify(data, null, 2) + "\n");
}

/** Reads CLI state from disk, returning defaults for missing fields. */
export function readCliState(): CliState {
  const raw = readRaw();

  return {
    lastModel: raw.last_model ?? null,
    preferences: {
      ...DEFAULT_PREFERENCES,
      ...(typeof raw.preferences === "object" && raw.preferences !== null ? raw.preferences : {}),
    },
    version: VERSION,
  };
}

/** Merges updates into CLI state and writes to disk. Returns updated state. */
export function writeCliState(updates: {
  lastModel?: Record<string, unknown> | null;
  preferences?: Record<string, unknown>;
}): CliState {
  const raw = readRaw();

  if (updates.lastModel !== undefined && updates.lastModel !== null) {
    raw.last_model = updates.lastModel;
  }

  if (updates.preferences && typeof updates.preferences === "object") {
    raw.preferences = { ...(raw.preferences ?? {}), ...updates.preferences };
  }

  writeRaw(raw);
  return readCliState();
}
