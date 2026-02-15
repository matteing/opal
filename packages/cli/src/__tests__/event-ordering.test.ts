import { describe, it, expect } from "vitest";
import { applyEvent, emptyState, combineDeltas } from "../lib/reducers.js";
import type { AgentEvent } from "../sdk/protocol.js";

/** Apply a sequence of events to a fresh state, returning the final result. */
function applySequence(events: AgentEvent[]) {
  let state = emptyState();
  for (const event of events) {
    state = applyEvent(state, event);
  }
  return state;
}

describe("event ordering — canonical sequences", () => {
  it("normal flow: agentStart → messageStart → messageDelta* → agentEnd", () => {
    const state = applySequence([
      { type: "agentStart" },
      { type: "messageStart" },
      { type: "messageDelta", delta: "Hello " },
      { type: "messageDelta", delta: "world" },
      {
        type: "agentEnd",
        usage: {
          promptTokens: 10,
          completionTokens: 5,
          totalTokens: 15,
          contextWindow: 128000,
          currentContextTokens: 20,
        },
      },
    ]);

    expect(state.main.isRunning).toBe(false);
    const msgs = state.main.timeline.filter((e) => e.kind === "message");
    expect(msgs).toHaveLength(1);
    expect(msgs[0].kind === "message" && msgs[0].message.content).toBe("Hello world");
    expect(state.tokenUsage?.totalTokens).toBe(15);
  });

  it("tool flow: agentStart → messageStart → toolStart → toolEnd → messageDelta → agentEnd", () => {
    const state = applySequence([
      { type: "agentStart" },
      { type: "messageStart" },
      {
        type: "toolExecutionStart",
        tool: "read_file",
        callId: "c1",
        args: { path: "file.txt" },
        meta: "Reading file.txt",
      },
      {
        type: "toolExecutionEnd",
        tool: "read_file",
        callId: "c1",
        result: { ok: true, output: "contents" },
      },
      { type: "messageDelta", delta: "Done." },
      { type: "agentEnd" },
    ]);

    const tools = state.main.timeline.filter((e) => e.kind === "tool");
    expect(tools).toHaveLength(1);
    expect(tools[0].kind === "tool" && tools[0].task.status).toBe("done");
    expect(state.main.isRunning).toBe(false);
  });

  it("abort flow: agentStart → messageDelta → agentAbort (no agentEnd)", () => {
    const state = applySequence([
      { type: "agentStart" },
      { type: "messageStart" },
      { type: "messageDelta", delta: "partial" },
      { type: "agentAbort" },
    ]);

    expect(state.main.isRunning).toBe(false);
    expect(state.main.thinking).toBeNull();
  });

  it("error mid-stream: agentStart → messageDelta → error", () => {
    const state = applySequence([
      { type: "agentStart" },
      { type: "messageStart" },
      { type: "messageDelta", delta: "partial" },
      { type: "error", reason: "API failure" },
    ]);

    expect(state.main.isRunning).toBe(false);
    expect(state.error).toBe("API failure");
  });

  it("thinking flow: agentStart → thinkingStart → thinkingDelta → messageStart → messageDelta → agentEnd", () => {
    const state = applySequence([
      { type: "agentStart" },
      { type: "thinkingStart" },
      { type: "thinkingDelta", delta: "Let me think..." },
      { type: "messageStart" },
      { type: "messageDelta", delta: "Here's my answer" },
      { type: "agentEnd" },
    ]);

    // Thinking should be cleared after agentEnd
    expect(state.main.thinking).toBeNull();
    // Timeline should have thinking entry
    const thinking = state.main.timeline.filter((e) => e.kind === "thinking");
    expect(thinking).toHaveLength(1);
    expect(thinking[0].kind === "thinking" && thinking[0].text).toBe("Let me think...");
  });

  it("sub-agent flow: toolStart(sub_agent) → subAgentEvent* → toolEnd → agentEnd", () => {
    const state = applySequence([
      { type: "agentStart" },
      { type: "messageStart" },
      {
        type: "toolExecutionStart",
        tool: "sub_agent",
        callId: "sa1",
        args: {},
        meta: "Spawning sub-agent",
      },
      {
        type: "subAgentEvent",
        parentCallId: "sa1",
        subSessionId: "sub-sess-1",
        inner: {
          type: "sub_agent_start",
          label: "Research Agent",
          model: "gpt-4",
          tools: ["read_file"],
        },
      } as unknown as AgentEvent,
      {
        type: "subAgentEvent",
        parentCallId: "sa1",
        subSessionId: "sub-sess-1",
        inner: { type: "agent_start" },
      } as unknown as AgentEvent,
      {
        type: "subAgentEvent",
        parentCallId: "sa1",
        subSessionId: "sub-sess-1",
        inner: { type: "agent_end" },
      } as unknown as AgentEvent,
      {
        type: "toolExecutionEnd",
        tool: "sub_agent",
        callId: "sa1",
        result: { ok: true, output: "done" },
      },
      { type: "agentEnd" },
    ]);

    // Sub-agent is cleaned up after agent_end inner event + top-level agentEnd clears subAgents
    expect(Object.keys(state.subAgents)).toHaveLength(0);
    expect(state.main.isRunning).toBe(false);
  });

  it("back-to-back turns: agentEnd resets state for next turn", () => {
    let state = emptyState();

    // Turn 1
    for (const event of [
      { type: "agentStart" } as AgentEvent,
      { type: "messageStart" } as AgentEvent,
      { type: "messageDelta", delta: "Turn 1" } as AgentEvent,
      { type: "agentEnd" } as AgentEvent,
    ]) {
      state = applyEvent(state, event);
    }
    expect(state.main.isRunning).toBe(false);

    // Turn 2
    for (const event of [
      { type: "agentStart" } as AgentEvent,
      { type: "messageStart" } as AgentEvent,
      { type: "messageDelta", delta: "Turn 2" } as AgentEvent,
      { type: "agentEnd" } as AgentEvent,
    ]) {
      state = applyEvent(state, event);
    }
    expect(state.main.isRunning).toBe(false);
    const messages = state.main.timeline.filter(
      (e) => e.kind === "message" && e.message.role === "assistant",
    );
    expect(messages).toHaveLength(2);
  });

  it("context + skills before first prompt", () => {
    const state = applySequence([
      { type: "contextDiscovered", files: ["AGENTS.md", "README.md"] } as AgentEvent,
      { type: "skillLoaded", name: "git", description: "Git operations" } as AgentEvent,
    ]);

    // Context discovered doesn't change main timeline in the reducer
    // (it's handled by the hook's markSessionReady)
    expect(state.main.isRunning).toBe(false);
  });

  it("recovery: agentRecovered event", () => {
    let state = emptyState();
    // Simulate agent was running
    state = applyEvent(state, { type: "agentStart" });
    expect(state.main.isRunning).toBe(true);

    // Recovery event
    state = applyEvent(state, { type: "agentRecovered" } as AgentEvent);
    // The reducer should handle this gracefully
    // (agentRecovered doesn't necessarily change isRunning — it's a notification)
  });

  it("statusUpdate during tools, cleared on agentEnd", () => {
    const state = applySequence([
      { type: "agentStart" },
      {
        type: "toolExecutionStart",
        tool: "shell",
        callId: "c1",
        args: {},
        meta: "",
      },
      { type: "statusUpdate", message: "Running shell command..." },
      {
        type: "toolExecutionEnd",
        tool: "shell",
        callId: "c1",
        result: { ok: true },
      },
      { type: "agentEnd" },
    ]);

    expect(state.main.statusMessage).toBeNull();
    expect(state.main.isRunning).toBe(false);
  });

  it("usageUpdate between tool calls", () => {
    const state = applySequence([
      { type: "agentStart" },
      {
        type: "usageUpdate",
        usage: {
          promptTokens: 50,
          completionTokens: 20,
          totalTokens: 70,
          contextWindow: 128000,
          currentContextTokens: 100,
        },
      } as AgentEvent,
      { type: "agentEnd" },
    ]);

    expect(state.tokenUsage?.totalTokens).toBe(70);
  });
});

describe("combineDeltas — batching", () => {
  it("combines consecutive messageDelta events", () => {
    const events: AgentEvent[] = [
      { type: "messageDelta", delta: "a" },
      { type: "messageDelta", delta: "b" },
      { type: "messageDelta", delta: "c" },
    ];
    const combined = combineDeltas(events);
    expect(combined).toHaveLength(1);
    expect(combined[0].type).toBe("messageDelta");
    expect((combined[0] as { delta: string }).delta).toBe("abc");
  });

  it("combines consecutive thinkingDelta events", () => {
    const events: AgentEvent[] = [
      { type: "thinkingDelta", delta: "x" },
      { type: "thinkingDelta", delta: "y" },
    ];
    const combined = combineDeltas(events);
    expect(combined).toHaveLength(1);
    expect((combined[0] as { delta: string }).delta).toBe("xy");
  });

  it("does not combine different event types", () => {
    const events: AgentEvent[] = [
      { type: "messageDelta", delta: "a" },
      { type: "agentStart" },
      { type: "messageDelta", delta: "b" },
    ];
    const combined = combineDeltas(events);
    expect(combined).toHaveLength(3);
  });

  it("preserves non-delta events", () => {
    const events: AgentEvent[] = [
      { type: "agentStart" },
      { type: "messageDelta", delta: "a" },
      { type: "messageDelta", delta: "b" },
      { type: "agentEnd" },
    ];
    const combined = combineDeltas(events);
    expect(combined).toHaveLength(3); // agentStart, combined delta, agentEnd
  });

  it("handles empty input", () => {
    expect(combineDeltas([])).toEqual([]);
  });

  it("handles single event", () => {
    const events: AgentEvent[] = [{ type: "agentStart" }];
    expect(combineDeltas(events)).toEqual(events);
  });

  it("50 rapid deltas combined into one", () => {
    const events: AgentEvent[] = Array.from({ length: 50 }, (_, i) => ({
      type: "messageDelta" as const,
      delta: String(i),
    }));
    const combined = combineDeltas(events);
    expect(combined).toHaveLength(1);
    const expected = Array.from({ length: 50 }, (_, i) => String(i)).join("");
    expect((combined[0] as { delta: string }).delta).toBe(expected);
  });

  it("mixed deltas: messageDelta then thinkingDelta not combined", () => {
    const events: AgentEvent[] = [
      { type: "messageDelta", delta: "a" },
      { type: "thinkingDelta", delta: "b" },
    ];
    const combined = combineDeltas(events);
    expect(combined).toHaveLength(2);
  });
});
