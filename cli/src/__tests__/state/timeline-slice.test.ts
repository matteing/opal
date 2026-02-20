import { describe, it, expect, beforeEach } from "vitest";
import { createStore } from "zustand/vanilla";
import { createTimelineSlice, type TimelineSlice, ROOT_AGENT_ID } from "../../state/timeline.js";
import { ev } from "./helpers.js";

function makeStore() {
  return createStore<TimelineSlice>()(createTimelineSlice);
}

/** Shorthand: root agent from store. */
function root(store: ReturnType<typeof makeStore>) {
  return store.getState().agents[ROOT_AGENT_ID]!;
}

describe("TimelineSlice (Zustand)", () => {
  let store: ReturnType<typeof makeStore>;

  beforeEach(() => {
    store = makeStore();
  });

  it("starts with root agent in agents map", () => {
    const s = store.getState();
    expect(s.agents).toHaveProperty(ROOT_AGENT_ID);
    expect(root(store).entries).toEqual([]);
    expect(root(store).isRunning).toBe(false);
    expect(root(store).thinking).toBeNull();
    expect(s.tokenUsage).toBeNull();
    expect(s.queuedMessages).toEqual([]);
    expect(s.timelineError).toBeNull();
    expect(s.focusStack).toEqual([ROOT_AGENT_ID]);
  });

  it("applyEvents processes a batch of events", () => {
    store.getState().applyEvents([
      ev.agentStart(),
      ev.messageStart(),
      ev.messageDelta("Hello "),
      ev.messageDelta("world"),
      ev.agentEnd(),
    ]);

    expect(root(store).isRunning).toBe(false);
    expect(root(store).entries).toHaveLength(1);
    expect(root(store).entries[0]).toEqual({
      kind: "message",
      message: { role: "assistant", content: "Hello world" },
    });
  });

  it("applyEvents is additive across calls", () => {
    store.getState().applyEvents([
      ev.messageApplied("first prompt"),
      ev.agentStart(),
      ev.messageStart(),
      ev.messageDelta("response 1"),
      ev.agentEnd(),
    ]);

    store.getState().applyEvents([
      ev.messageApplied("second prompt"),
      ev.agentStart(),
      ev.messageStart(),
      ev.messageDelta("response 2"),
      ev.agentEnd(),
    ]);

    expect(root(store).entries).toHaveLength(4);
  });

  it("resetTimeline clears everything", () => {
    store.getState().applyEvents([
      ev.agentStart(),
      ev.messageStart(),
      ev.messageDelta("Hi"),
      ev.agentEnd({
        promptTokens: 10,
        completionTokens: 5,
        totalTokens: 15,
        contextWindow: 128_000,
        currentContextTokens: 100,
      }),
    ]);

    store.getState().resetTimeline();

    expect(root(store).entries).toEqual([]);
    expect(root(store).isRunning).toBe(false);
    expect(store.getState().tokenUsage).toBeNull();
    expect(store.getState().queuedMessages).toEqual([]);
    expect(store.getState().timelineError).toBeNull();
  });

  it("handles interleaved tool calls in a batch", () => {
    store.getState().applyEvents([
      ev.agentStart(),
      ev.toolStart("read_file", "c1", { path: "foo.ts" }, "reading foo"),
      ev.toolStart("read_file", "c2", { path: "bar.ts" }, "reading bar"),
      ev.toolEnd("read_file", "c1", true, "content1"),
      ev.toolEnd("read_file", "c2", true, "content2"),
      ev.agentEnd(),
    ]);

    const tools = root(store).entries.filter((e) => e.kind === "tool");
    expect(tools).toHaveLength(2);
    expect(tools.every((e) => e.kind === "tool" && e.tool.status === "done")).toBe(true);
  });

  it("notifies subscribers on state change", () => {
    const snapshots: boolean[] = [];
    store.subscribe((state) => {
      snapshots.push(state.agents[ROOT_AGENT_ID]!.isRunning);
    });

    store.getState().applyEvents([ev.agentStart()]);
    store.getState().applyEvents([ev.agentEnd()]);

    expect(snapshots).toEqual([true, false]);
  });

  it("focusAgent pushes onto the focus stack", () => {
    store.getState().applyEvents([
      ev.agentStart(),
      ev.subAgentEvent("sub1", "c1", {
        type: "sub_agent_start",
        label: "worker",
        model: "gpt-4",
        tools: [],
      }),
    ]);

    store.getState().focusAgent("sub1");
    expect(store.getState().focusStack).toEqual([ROOT_AGENT_ID, "sub1"]);
  });

  it("focusBack pops the focus stack", () => {
    store.getState().applyEvents([
      ev.agentStart(),
      ev.subAgentEvent("sub1", "c1", {
        type: "sub_agent_start",
        label: "worker",
        model: "gpt-4",
        tools: [],
      }),
    ]);

    store.getState().focusAgent("sub1");
    store.getState().focusBack();
    expect(store.getState().focusStack).toEqual([ROOT_AGENT_ID]);
  });

  it("focusBack does not pop past root", () => {
    store.getState().focusBack();
    expect(store.getState().focusStack).toEqual([ROOT_AGENT_ID]);
  });

  it("focusAgent ignores unknown agent IDs", () => {
    store.getState().focusAgent("nonexistent");
    expect(store.getState().focusStack).toEqual([ROOT_AGENT_ID]);
  });
});
