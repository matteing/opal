/**
 * CLI state slice — persistent CLI preferences and command history.
 *
 * Manages CLI-specific state that persists across sessions:
 * - Last used model configuration
 * - User preferences (auto-confirm, verbose)
 * - Command history for arrow key navigation
 *
 * All persistence is local (filesystem) — no RPC needed.
 *
 * @module
 */

import type { StateCreator } from "zustand";
import { type CliState, readCliState, writeCliState } from "../sdk/cli-state.js";
import { type HistoryEntry, readHistory, appendHistory } from "../sdk/cli-history.js";

// ── History container (matches old CliHistoryGetResult shape) ─────

export interface CommandHistory {
  commands: HistoryEntry[];
  maxSize: number;
}

// ── Slice state + actions ────────────────────────────────────────

export interface CliStateSlice {
  // State
  cliState: CliState | null;
  commandHistory: CommandHistory | null;
  historyIndex: number;
  cliStateLoading: boolean;
  cliStateError: string | null;

  // Actions
  /** Load CLI state and command history from local files. */
  loadCliState: () => void;
  /** Update CLI state to local files. */
  updateCliState: (updates: { lastModel?: Record<string, unknown> | null; preferences?: Record<string, unknown> }) => void;
  /** Add a command to history (persisted to disk). */
  addToHistory: (command: string) => void;

  // History navigation
  /** Get the previous command in history. Returns null if at the beginning. */
  getPreviousCommand: () => string | null;
  /** Get the next command in history. Returns null if at the end. */
  getNextCommand: () => string | null;
  /** Reset history navigation to the end (for new input). */
  resetHistoryNavigation: () => void;
}

// ── Slice creator ────────────────────────────────────────────────

const MAX_HISTORY = 200;

export const createCliStateSlice: StateCreator<CliStateSlice, [], [], CliStateSlice> = (
  set,
  get,
) => ({
  // Initial state
  cliState: null,
  commandHistory: null,
  historyIndex: -1, // -1 means "at end" (new input)
  cliStateLoading: false,
  cliStateError: null,

  // Load CLI state and history from local files
  loadCliState: () => {
    try {
      const state = readCliState();
      const commands = readHistory();

      set({
        cliState: state,
        commandHistory: { commands, maxSize: MAX_HISTORY },
        historyIndex: -1,
        cliStateLoading: false,
        cliStateError: null,
      });
    } catch (err: unknown) {
      set({
        cliStateError: err instanceof Error ? err.message : String(err),
        cliStateLoading: false,
      });
    }
  },

  // Update CLI state (local file)
  updateCliState: (updates) => {
    try {
      const result = writeCliState(updates);
      set({ cliState: result });
    } catch (err: unknown) {
      set({
        cliStateError: err instanceof Error ? err.message : String(err),
      });
    }
  },

  // Add command to history and persist to disk
  addToHistory: (command) => {
    try {
      const updated = appendHistory(command);
      set({
        commandHistory: { commands: updated, maxSize: MAX_HISTORY },
        historyIndex: -1,
      });
    } catch {
      // Best-effort — don't break the UI if history write fails
    }
  },

  // History navigation
  getPreviousCommand: () => {
    const { commandHistory, historyIndex } = get();
    if (!commandHistory || commandHistory.commands.length === 0) {
      return null;
    }

    const newIndex =
      historyIndex === -1
        ? 0 // First time pressing up
        : Math.min(historyIndex + 1, commandHistory.commands.length - 1);

    if (newIndex < commandHistory.commands.length) {
      set({ historyIndex: newIndex });
      return commandHistory.commands[newIndex].text;
    }

    return null;
  },

  getNextCommand: () => {
    const { commandHistory, historyIndex } = get();
    if (!commandHistory || historyIndex <= 0) {
      // At end or no history
      if (historyIndex === 0) {
        set({ historyIndex: -1 }); // Reset to end
      }
      return null;
    }

    const newIndex = historyIndex - 1;
    if (newIndex === -1) {
      // Back to "new input" state
      set({ historyIndex: -1 });
      return null;
    }

    set({ historyIndex: newIndex });
    return commandHistory.commands[newIndex].text;
  },

  resetHistoryNavigation: () => {
    set({ historyIndex: -1 });
  },
});
