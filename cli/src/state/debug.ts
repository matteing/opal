/**
 * Debug slice — RPC message log and server stderr capture.
 *
 * Maintains a capped ring buffer of RPC messages and stderr lines.
 * Provides callbacks to wire into the transport layer.
 *
 * @module
 */

import type { StateCreator } from "zustand";
import type { RpcLogEntry, StderrEntry } from "./types.js";

// ── Constants ────────────────────────────────────────────────────

const MAX_RPC_ENTRIES = 200;
const MAX_STDERR_LINES = 50;

// ── Slice state + actions ────────────────────────────────────────

export interface DebugSlice {
  rpcEntries: readonly RpcLogEntry[];
  stderrLines: readonly StderrEntry[];
  debugVisible: boolean;
  showToolOutput: boolean;

  /** Append an RPC message to the log. */
  pushRpcMessage: (entry: Omit<RpcLogEntry, "id">) => void;
  /** Append server stderr output. */
  pushStderr: (data: string) => void;
  /** Toggle debug panel visibility. */
  toggleDebug: () => void;
  /** Toggle tool output display in the timeline. */
  toggleToolOutput: () => void;
  /** Clear all debug log entries. */
  clearDebug: () => void;
}

// ── Slice creator ────────────────────────────────────────────────

let nextRpcId = 0;

export const createDebugSlice: StateCreator<
  DebugSlice,
  [],
  [],
  DebugSlice
> = (set) => ({
  rpcEntries: [],
  stderrLines: [],
  debugVisible: false,
  showToolOutput: false,

  pushRpcMessage: (entry) => {
    const numbered = { ...entry, id: ++nextRpcId };
    set((state) => ({
      rpcEntries:
        state.rpcEntries.length >= MAX_RPC_ENTRIES
          ? [...state.rpcEntries.slice(-(MAX_RPC_ENTRIES - 1)), numbered]
          : [...state.rpcEntries, numbered],
    }));
  },

  pushStderr: (data) => {
    const lines = data
      .split("\n")
      .map((l) => l.trim())
      .filter((l) => l.length > 0);
    if (lines.length === 0) return;

    const now = Date.now();
    const entries = lines.map((text) => ({ timestamp: now, text }));
    set((state) => ({
      stderrLines: [...state.stderrLines, ...entries].slice(-MAX_STDERR_LINES),
    }));
  },

  toggleDebug: () =>
    set((state) => ({ debugVisible: !state.debugVisible })),

  toggleToolOutput: () =>
    set((state) => ({ showToolOutput: !state.showToolOutput })),

  clearDebug: () =>
    set({ rpcEntries: [], stderrLines: [] }),
});
