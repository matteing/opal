import { describe, it, expect, beforeEach, vi } from "vitest";
import { createStore } from "zustand/vanilla";
import { createCliStateSlice, type CliStateSlice } from "../../state/cli.js";
import type { Session } from "../../sdk/session.js";

// ── Helpers ──────────────────────────────────────────────────────

function makeStore() {
  return createStore<CliStateSlice>()(createCliStateSlice);
}

function mockSession(overrides: Partial<Session["cli"]> = {}): Session {
  return {
    cli: {
      getState: vi.fn().mockResolvedValue({
        lastModel: { id: "gpt-4", provider: "copilot", thinkingLevel: "off" },
        preferences: { autoConfirm: false, verbose: false },
        version: 1,
      }),
      setState: vi.fn().mockImplementation(async (updates) => ({
        lastModel: updates.lastModel ?? { id: "gpt-4", provider: "copilot" },
        preferences: { autoConfirm: false, verbose: false, ...updates.preferences },
        version: 1,
      })),
      getHistory: vi.fn().mockResolvedValue({
        commands: [
          { text: "ls -la", timestamp: "2026-01-01T00:00:00Z" },
          { text: "git status", timestamp: "2026-01-01T00:01:00Z" },
        ],
        maxSize: 500,
        version: 1,
      }),
      ...overrides,
    },
  } as unknown as Session;
}

// ── Tests ────────────────────────────────────────────────────────

describe("CliStateSlice", () => {
  let store: ReturnType<typeof makeStore>;

  beforeEach(() => {
    store = makeStore();
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

  it("loads state and history from session", async () => {
    const session = mockSession();
    await store.getState().loadCliState(session);

    const s = store.getState();
    expect(s.cliState).not.toBeNull();
    expect(s.cliState?.lastModel?.id).toBe("gpt-4");
    expect(s.commandHistory?.commands).toHaveLength(2);
    expect(s.cliStateLoading).toBe(false);
    expect(s.historyIndex).toBe(-1);
  });

  it("sets loading state during fetch", async () => {
    let resolveState!: (v: unknown) => void;
    const session = mockSession({
      getState: vi.fn().mockReturnValue(
        new Promise((r) => {
          resolveState = r;
        }),
      ),
      getHistory: vi.fn().mockResolvedValue({ commands: [], maxSize: 500, version: 1 }),
    });

    const promise = store.getState().loadCliState(session);
    expect(store.getState().cliStateLoading).toBe(true);

    resolveState({ preferences: { autoConfirm: false, verbose: false }, version: 1 });
    await promise;
    expect(store.getState().cliStateLoading).toBe(false);
  });

  it("handles load errors", async () => {
    const session = mockSession({
      getState: vi.fn().mockRejectedValue(new Error("network error")),
    });

    await store.getState().loadCliState(session);
    expect(store.getState().cliStateError).toBe("network error");
    expect(store.getState().cliStateLoading).toBe(false);
  });

  // ── updateCliState ───────────────────────────────────────────

  it("updates state on the server and stores result", async () => {
    const session = mockSession();
    await store.getState().updateCliState(session, {
      lastModel: { id: "claude-4", provider: "copilot" },
    });

    expect(session.cli.setState).toHaveBeenCalledWith({
      lastModel: { id: "claude-4", provider: "copilot" },
    });
    expect(store.getState().cliState).not.toBeNull();
    expect(store.getState().cliStateLoading).toBe(false);
  });

  it("handles update errors", async () => {
    const session = mockSession({
      setState: vi.fn().mockRejectedValue(new Error("save failed")),
    });

    await store.getState().updateCliState(session, {});
    expect(store.getState().cliStateError).toBe("save failed");
  });

  // ── addToHistory ─────────────────────────────────────────────

  it("adds to local history", async () => {
    const session = mockSession();
    // First load history
    await store.getState().loadCliState(session);

    store.getState().addToHistory("npm test");

    const history = store.getState().commandHistory;
    expect(history?.commands[0].text).toBe("npm test");
    expect(history?.commands).toHaveLength(3);
  });

  it("skips duplicate consecutive commands", async () => {
    const session = mockSession();
    await store.getState().loadCliState(session);

    // "ls -la" is already the most recent command
    store.getState().addToHistory("ls -la");

    const history = store.getState().commandHistory;
    expect(history?.commands).toHaveLength(2); // Unchanged
  });

  it("resets historyIndex after adding", async () => {
    const session = mockSession();
    await store.getState().loadCliState(session);

    // Navigate up first
    store.getState().getPreviousCommand();
    expect(store.getState().historyIndex).toBe(0);

    store.getState().addToHistory("new command");
    expect(store.getState().historyIndex).toBe(-1);
  });

  // ── History navigation ───────────────────────────────────────

  it("getPreviousCommand returns commands in reverse order", async () => {
    const session = mockSession();
    await store.getState().loadCliState(session);

    const first = store.getState().getPreviousCommand();
    expect(first).toBe("ls -la");

    const second = store.getState().getPreviousCommand();
    expect(second).toBe("git status");
  });

  it("getPreviousCommand stays at oldest entry", async () => {
    const session = mockSession();
    await store.getState().loadCliState(session);

    store.getState().getPreviousCommand(); // ls -la
    store.getState().getPreviousCommand(); // git status
    const third = store.getState().getPreviousCommand(); // still git status

    expect(third).toBe("git status");
  });

  it("getPreviousCommand returns null with no history", () => {
    expect(store.getState().getPreviousCommand()).toBeNull();
  });

  it("getNextCommand navigates forward", async () => {
    const session = mockSession();
    await store.getState().loadCliState(session);

    store.getState().getPreviousCommand(); // ls -la (index 0)
    store.getState().getPreviousCommand(); // git status (index 1)

    const next = store.getState().getNextCommand();
    expect(next).toBe("ls -la");
  });

  it("getNextCommand returns null at end", async () => {
    const session = mockSession();
    await store.getState().loadCliState(session);

    store.getState().getPreviousCommand(); // index 0
    store.getState().getNextCommand(); // back to -1

    expect(store.getState().historyIndex).toBe(-1);
    expect(store.getState().getNextCommand()).toBeNull();
  });

  it("resetHistoryNavigation resets index", async () => {
    const session = mockSession();
    await store.getState().loadCliState(session);

    store.getState().getPreviousCommand();
    expect(store.getState().historyIndex).toBe(0);

    store.getState().resetHistoryNavigation();
    expect(store.getState().historyIndex).toBe(-1);
  });
});
