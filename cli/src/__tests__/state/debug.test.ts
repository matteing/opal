import { describe, it, expect, beforeEach } from "vitest";
import { createStore } from "zustand/vanilla";
import { createDebugSlice, type DebugSlice } from "../../state/debug.js";

function makeStore() {
  return createStore<DebugSlice>()(createDebugSlice);
}

describe("DebugSlice", () => {
  let store: ReturnType<typeof makeStore>;

  beforeEach(() => {
    store = makeStore();
  });

  // ── RPC entries ──────────────────────────────────────────────

  it("starts with empty entries", () => {
    expect(store.getState().rpcEntries).toEqual([]);
    expect(store.getState().stderrLines).toEqual([]);
    expect(store.getState().debugVisible).toBe(false);
  });

  it("pushRpcMessage appends an entry with auto-incrementing id", () => {
    store.getState().pushRpcMessage({
      direction: "outgoing",
      timestamp: 1000,
      raw: { method: "agent/prompt" },
      method: "agent/prompt",
      kind: "request",
    });

    const entries = store.getState().rpcEntries;
    expect(entries).toHaveLength(1);
    expect(entries[0].direction).toBe("outgoing");
    expect(entries[0].method).toBe("agent/prompt");
    expect(entries[0].kind).toBe("request");
    expect(typeof entries[0].id).toBe("number");
  });

  it("pushRpcMessage assigns unique ids across calls", () => {
    const push = store.getState().pushRpcMessage;
    push({ direction: "outgoing", timestamp: 1, raw: {}, kind: "request" });
    push({ direction: "incoming", timestamp: 2, raw: {}, kind: "response" });

    const entries = store.getState().rpcEntries;
    expect(entries[0].id).not.toBe(entries[1].id);
  });

  it("caps entries at 200", () => {
    const push = store.getState().pushRpcMessage;
    for (let i = 0; i < 210; i++) {
      push({ direction: "outgoing", timestamp: i, raw: {}, kind: "request" });
    }
    expect(store.getState().rpcEntries).toHaveLength(200);
    // Oldest entries were dropped
    expect(store.getState().rpcEntries[0].timestamp).toBeGreaterThan(0);
  });

  // ── Stderr ───────────────────────────────────────────────────

  it("pushStderr captures lines and ignores empty", () => {
    store.getState().pushStderr("line one\n  \nline two\n");
    const lines = store.getState().stderrLines;
    expect(lines).toHaveLength(2);
    expect(lines[0].text).toBe("line one");
    expect(lines[1].text).toBe("line two");
  });

  it("pushStderr ignores fully empty input", () => {
    store.getState().pushStderr("  \n  \n");
    expect(store.getState().stderrLines).toHaveLength(0);
  });

  it("caps stderr at 50 lines", () => {
    const push = store.getState().pushStderr;
    for (let i = 0; i < 60; i++) {
      push(`line ${i}`);
    }
    expect(store.getState().stderrLines).toHaveLength(50);
  });

  // ── Toggle & clear ──────────────────────────────────────────

  it("toggleDebug flips visibility", () => {
    expect(store.getState().debugVisible).toBe(false);
    store.getState().toggleDebug();
    expect(store.getState().debugVisible).toBe(true);
    store.getState().toggleDebug();
    expect(store.getState().debugVisible).toBe(false);
  });

  it("clearDebug empties entries and stderr", () => {
    store.getState().pushRpcMessage({
      direction: "outgoing",
      timestamp: 1,
      raw: {},
      kind: "request",
    });
    store.getState().pushStderr("some error");
    store.getState().clearDebug();

    expect(store.getState().rpcEntries).toEqual([]);
    expect(store.getState().stderrLines).toEqual([]);
  });
});
