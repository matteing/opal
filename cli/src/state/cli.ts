/**
 * CLI state slice — persistent CLI preferences and command history.
 *
 * Manages CLI-specific state that persists across sessions:
 * - Last used model configuration
 * - User preferences (auto-confirm, verbose)
 * - Command history for arrow key navigation
 *
 * @module
 */

import type { StateCreator } from "zustand";
import type { Session } from "../sdk/session.js";
import type { CliStateGetResult, CliHistoryGetResult, CliStateSetParams } from "../sdk/protocol.js";

// ── Slice state + actions ────────────────────────────────────────

export interface CliStateSlice {
  // State
  cliState: CliStateGetResult | null;
  commandHistory: CliHistoryGetResult | null;
  historyIndex: number;
  cliStateLoading: boolean;
  cliStateError: string | null;

  // Actions
  /** Load CLI state and command history from server. */
  loadCliState: (session: Session) => Promise<void>;
  /** Update CLI state on the server. */
  updateCliState: (session: Session, updates: Partial<CliStateSetParams>) => Promise<void>;
  /** Add a command to the local history (no server call). */
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

  // Load CLI state and history
  loadCliState: async (session) => {
    set({ cliStateLoading: true, cliStateError: null });

    try {
      const [stateRes, historyRes] = await Promise.all([
        session.cli.getState(),
        session.cli.getHistory(),
      ]);

      set({
        cliState: stateRes,
        commandHistory: historyRes,
        historyIndex: -1, // Reset to end
        cliStateLoading: false,
      });
    } catch (err: unknown) {
      set({
        cliStateError: err instanceof Error ? err.message : String(err),
        cliStateLoading: false,
      });
    }
  },

  // Update CLI state
  updateCliState: async (session, updates) => {
    set({ cliStateLoading: true, cliStateError: null });

    try {
      const result = await session.cli.setState(updates);
      set({
        cliState: result,
        cliStateLoading: false,
      });
    } catch (err: unknown) {
      set({
        cliStateError: err instanceof Error ? err.message : String(err),
        cliStateLoading: false,
      });
    }
  },

  // Add command to local history (no server round-trip; sessions persist prompts)
  addToHistory: (command) => {
    const { commandHistory } = get();
    if (!commandHistory) return;

    const newEntry = {
      text: command,
      timestamp: new Date().toISOString(),
    };

    // Don't add if it's identical to the last command
    const lastCommand = commandHistory.commands[0]?.text;
    if (lastCommand === command) return;

    set({
      commandHistory: {
        ...commandHistory,
        commands: [newEntry, ...commandHistory.commands.slice(0, commandHistory.maxSize - 1)],
      },
      historyIndex: -1,
    });
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
