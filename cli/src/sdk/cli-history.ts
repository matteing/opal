/**
 * File-based command history persistence.
 *
 * Stores history as a JSON array in `<dataDir>/cli_state.json` under the
 * `"history"` key, co-located with CLI state for simplicity.
 *
 * @module
 */

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { getDataDir } from "./cli-state.js";

// ── Types ────────────────────────────────────────────────────────

export interface HistoryEntry {
  text: string;
  timestamp: string;
}

const MAX_HISTORY = 200;

// ── Helpers ──────────────────────────────────────────────────────

function historyPath(): string {
  return join(getDataDir(), "cli_state.json");
}

function readRaw(): Record<string, unknown> {
  try {
    const data = readFileSync(historyPath(), "utf-8");
    const parsed: unknown = JSON.parse(data);
    return typeof parsed === "object" && parsed !== null ? (parsed as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

function writeRaw(data: Record<string, unknown>): void {
  const dir = getDataDir();
  mkdirSync(dir, { recursive: true });
  writeFileSync(historyPath(), JSON.stringify(data, null, 2) + "\n");
}

// ── Public API ───────────────────────────────────────────────────

/** Reads command history from disk. Returns newest-first. */
export function readHistory(): HistoryEntry[] {
  const raw = readRaw();
  const history = raw.history;

  if (!Array.isArray(history)) return [];
  return history.filter(
    (e: unknown): e is HistoryEntry =>
      typeof e === "object" &&
      e !== null &&
      typeof (e as HistoryEntry).text === "string" &&
      typeof (e as HistoryEntry).timestamp === "string",
  );
}

/** Appends a command to history. Deduplicates consecutive, caps at MAX_HISTORY. */
export function appendHistory(command: string): HistoryEntry[] {
  const entries = readHistory();

  // Skip if identical to most recent
  if (entries.length > 0 && entries[0].text === command) return entries;

  const entry: HistoryEntry = {
    text: command,
    timestamp: new Date().toISOString(),
  };

  const updated = [entry, ...entries].slice(0, MAX_HISTORY);

  const raw = readRaw();
  raw.history = updated;
  writeRaw(raw);

  return updated;
}
