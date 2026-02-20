import { describe, it, expect } from "vitest";
import { create } from "zustand";
import { createTimelineSlice, type TimelineSlice, ROOT_AGENT_ID } from "../../state/timeline.js";
import { createDebugSlice, type DebugSlice } from "../../state/debug.js";
import { createModelsSlice, type ModelsSlice } from "../../state/models.js";
import { createAuthSlice, type AuthSlice } from "../../state/auth.js";
import { createCliStateSlice, type CliStateSlice } from "../../state/cli.js";
import { ev } from "./helpers.js";

/**
 * Integration test — compose slices into one store
 * (without the session slice which needs real I/O).
 */
type TestStore = TimelineSlice & DebugSlice & ModelsSlice & AuthSlice & CliStateSlice;

function makeComposedStore() {
  return create<TestStore>()((...a) => ({
    ...createTimelineSlice(...a),
    ...createDebugSlice(...a),
    ...createModelsSlice(...a),
    ...createAuthSlice(...a),
    ...createCliStateSlice(...a),
  }));
}

/** Shorthand: root agent entries. */
function rootEntries(store: ReturnType<typeof makeComposedStore>) {
  return store.getState().agents[ROOT_AGENT_ID].entries;
}

describe("Composed store", () => {
  it("slices coexist without conflicts", () => {
    const store = makeComposedStore();
    const s = store.getState();

    // Timeline
    expect(s.agents).toHaveProperty(ROOT_AGENT_ID);
    expect(s.agents[ROOT_AGENT_ID].isRunning).toBe(false);
    // Debug
    expect(s.rpcEntries).toEqual([]);
    expect(s.debugVisible).toBe(false);
    // Models
    expect(s.availableModels).toEqual([]);
    expect(s.currentModel).toBeNull();
    // Auth
    expect(s.authStatus).toBe("checking");
  });

  it("timeline mutations don't affect debug state", () => {
    const store = makeComposedStore();

    store.getState().pushRpcMessage({
      direction: "outgoing",
      timestamp: 1,
      raw: {},
      kind: "request",
    });

    store
      .getState()
      .applyEvents([ev.agentStart(), ev.messageStart(), ev.messageDelta("Hi"), ev.agentEnd()]);

    // RPC entries preserved after timeline mutation
    expect(store.getState().rpcEntries).toHaveLength(1);
    // Timeline updated
    expect(rootEntries(store)).toHaveLength(1);
  });

  it("resetTimeline only resets timeline, not debug", () => {
    const store = makeComposedStore();

    store.getState().pushRpcMessage({
      direction: "incoming",
      timestamp: 1,
      raw: {},
      kind: "notification",
    });
    store
      .getState()
      .applyEvents([ev.agentStart(), ev.messageStart(), ev.messageDelta("data"), ev.agentEnd()]);
    store.getState().toggleDebug();

    store.getState().resetTimeline();

    expect(rootEntries(store)).toEqual([]);
    expect(store.getState().rpcEntries).toHaveLength(1);
    expect(store.getState().debugVisible).toBe(true);
  });

  it("subscribe fires on every state change", () => {
    const store = makeComposedStore();
    const snapshots: { entries: number; rpc: number }[] = [];

    store.subscribe((state) => {
      snapshots.push({
        entries: state.agents[ROOT_AGENT_ID].entries.length,
        rpc: state.rpcEntries.length,
      });
    });

    // Timeline mutation
    store
      .getState()
      .applyEvents([ev.agentStart(), ev.messageStart(), ev.messageDelta("Hi"), ev.agentEnd()]);

    // Debug mutation
    store.getState().pushRpcMessage({
      direction: "outgoing",
      timestamp: 1,
      raw: {},
      kind: "request",
    });

    expect(snapshots).toHaveLength(2);
    expect(snapshots[0]).toEqual({ entries: 1, rpc: 0 });
    expect(snapshots[1]).toEqual({ entries: 1, rpc: 1 });
  });

  it("types are compatible with the full OpalStore shape", () => {
    const store = makeComposedStore();
    const state = store.getState();

    const check: {
      agents: typeof state.agents;
      rpcEntries: typeof state.rpcEntries;
      currentModel: typeof state.currentModel;
      authStatus: typeof state.authStatus;
    } = {
      agents: state.agents,
      rpcEntries: state.rpcEntries,
      currentModel: state.currentModel,
      authStatus: state.authStatus,
    };

    expect(check).toBeDefined();
  });
});
