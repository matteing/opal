import { describe, it, expect, beforeEach, vi } from "vitest";
import { createStore } from "zustand/vanilla";
import { createCliStateSlice, type CliStateSlice } from "../../state/cli.js";

// Mock file-based modules
vi.mock("../../sdk/cli-state.js", () => ({
  readCliState: vi.fn().mockReturnValue({
    lastModel: { id: "gpt-4", provider: "copilot", thinkingLevel: "off" },
    preferences: { autoConfirm: false, verbose: false },
    version: 1,
  }),
  writeCliState: vi.fn().mockImplementation((updates) => ({
    lastModel: updates.lastModel ?? { id: "gpt-4", provider: "copilot" },
    preferences: { autoConfirm: false, verbose: false, ...updates.preferences },
    version: 1,
  })),
}));

vi.mock("../../sdk/cli-history.js", () => ({
  readHistory: vi.fn().mockReturnValue([
    { text: "ls -la", timestamp: "2026-01-01T00:00:00Z" },
    { text: "git status", timestamp: "2026-01-01T00:01:00Z" },
  ]),
  appendHistory: vi.fn().mockImplementation((command) => [
    { text: command, timestamp: new Date().toISOString() },
    { text: "ls -la", timestamp: "2026-01-01T00:00:00Z" },
    { text: "git status", timestamp: "2026-01-01T00:01:00Z" },
  ]),
}));

import { readCliState, writeCliState } from "../../sdk/cli-state.js";
import { readHistory, appendHistory } from "../../sdk/cli-history.js";

// ── Helpers ──────────────────────────────────────────────────────

function makeStore() {
  return createStore<CliStateSlice>()(createCliStateSlice);
}

// ── Tests ────────────────────────────────────────────────────────

describe("CliStateSlice", () => {
  let store: ReturnType<typeof makeStore>;

  beforeEach(() => {
    store = makeStore();

    // Re-apply default mock implementations (clearAllMocks wipes them)
    vi.mocked(readCliState).mockReturnValue({
      lastModel: { id: "gpt-4", provider: "copilot", thinkingLevel: "off" },
      preferences: { autoConfirm: false, verbose: false },
      version: 1,
    });
    vi.mocked(readHistory).mockReturnValue([
      { text: "ls -la", timestamp: "2026-01-01T00:00:00Z" },
      { text: "git status", timestamp: "2026-01-01T00:01:00Z" },
    ]);
    vi.mocked(appendHistory).mockImplementation((command) => [
      { text: command, timestamp: new Date().toISOString() },
      { text: "ls -la", timestamp: "2026-01-01T00:00:00Z" },
      { text: "git status", timestamp: "2026-01-01T00:01:00Z" },
    ]);
    vi.mocked(writeCliState).mockImplementation((updates) => ({
      lastModel: (updates.lastModel as Record<string, unknown>) ?? {
        id: "gpt-4",
        provider: "copilot",
      },
      preferences: {
        autoConfirm: false,
        verbose: false,
        ...((updates.preferences as Record<string, boolean>) ?? {}),
      },
      version: 1,
    }));
  });

  // ── Initial state ────────────────────────────────────────────

  it("starts with null state and history", () => {
    const s = store.getState();
    expect(s.cliState).toBeNull();
    expect(s.commandHistory).toBeNull();
    expect(s.historyIndex).toBe(-1);
    expect(s.cliStateLoading).toBe(false);
    expect(s.cliStateError).toBeNull();
  });

  // ── loadCliState ─────────────────────────────────────────────

  it("loads state and history from local files", () => {
    store.getState().loadCliState();

    const s = store.getState();
    expect(readCliState).toHaveBeenCalled();
    expect(readHistory).toHaveBeenCalled();
    expect(s.cliState).not.toBeNull();
    expect(s.cliState?.lastModel?.id).toBe("gpt-4");
    expect(s.commandHistory?.commands).toHaveLength(2);
    expect(s.cliStateLoading).toBe(false);
    expect(s.historyIndex).toBe(-1);
  });

  it("handles load errors", () => {
    vi.mocked(readCliState).mockImplementation(() => {
      throw new Error("file corrupt");
    });

    store.getState().loadCliState();
    expect(store.getState().cliStateError).toBe("file corrupt");
    expect(store.getState().cliStateLoading).toBe(false);
  });

  // ── updateCliState ───────────────────────────────────────────

  it("writes state to local file and stores result", () => {
    store.getState().updateCliState({
      lastModel: { id: "claude-4", provider: "copilot" },
    });

    expect(writeCliState).toHaveBeenCalledWith({
      lastModel: { id: "claude-4", provider: "copilot" },
    });
    expect(store.getState().cliState).not.toBeNull();
  });

  it("handles write errors", () => {
    vi.mocked(writeCliState).mockImplementation(() => {
      throw new Error("disk full");
    });

    store.getState().updateCliState({});
    expect(store.getState().cliStateError).toBe("disk full");
  });

  // ── addToHistory ─────────────────────────────────────────────

  it("adds to history and persists to disk", () => {
    store.getState().loadCliState();
    store.getState().addToHistory("npm test");

    expect(appendHistory).toHaveBeenCalledWith("npm test");
    const history = store.getState().commandHistory;
    expect(history?.commands[0].text).toBe("npm test");
    expect(history?.commands).toHaveLength(3);
  });

  it("resets historyIndex after adding", () => {
    store.getState().loadCliState();

    // Navigate up first
    store.getState().getPreviousCommand();
    expect(store.getState().historyIndex).toBe(0);

    store.getState().addToHistory("new command");
    expect(store.getState().historyIndex).toBe(-1);
  });

  // ── History navigation ───────────────────────────────────────

  it("getPreviousCommand returns commands in reverse order", () => {
    store.getState().loadCliState();

    const first = store.getState().getPreviousCommand();
    expect(first).toBe("ls -la");

    const second = store.getState().getPreviousCommand();
    expect(second).toBe("git status");
  });

  it("getPreviousCommand stays at oldest entry", () => {
    store.getState().loadCliState();

    store.getState().getPreviousCommand(); // ls -la
    store.getState().getPreviousCommand(); // git status
    const third = store.getState().getPreviousCommand(); // still git status

    expect(third).toBe("git status");
  });

  it("getPreviousCommand returns null with no history", () => {
    expect(store.getState().getPreviousCommand()).toBeNull();
  });

  it("getNextCommand navigates forward", () => {
    store.getState().loadCliState();

    store.getState().getPreviousCommand(); // ls -la (index 0)
    store.getState().getPreviousCommand(); // git status (index 1)

    const next = store.getState().getNextCommand();
    expect(next).toBe("ls -la");
  });

  it("getNextCommand returns null at end", () => {
    store.getState().loadCliState();

    store.getState().getPreviousCommand(); // index 0
    store.getState().getNextCommand(); // back to -1

    expect(store.getState().historyIndex).toBe(-1);
    expect(store.getState().getNextCommand()).toBeNull();
  });

  it("resetHistoryNavigation resets index", () => {
    store.getState().loadCliState();

    store.getState().getPreviousCommand();
    expect(store.getState().historyIndex).toBe(0);

    store.getState().resetHistoryNavigation();
    expect(store.getState().historyIndex).toBe(-1);
  });
});
