import { describe, it, expect } from "vitest";
import type { AgentEvent } from "../sdk/protocol.js";
import {
  applyAgentEvent,
  applyEvent,
  combineDeltas,
  emptyAgentView,
  emptyState,
  type AgentView,
} from "../lib/reducers.js";

function view(overrides: Partial<AgentView> = {}): AgentView {
  return { ...emptyAgentView(), ...overrides };
}

describe("applyAgentEvent", () => {
  it("agentStart sets isRunning true", () => {
    const result = applyAgentEvent(view(), { type: "agentStart" });
    expect(result.isRunning).toBe(true);
  });

  it("agent_start (snake_case) sets isRunning true", () => {
    const result = applyAgentEvent(view(), { type: "agent_start" });
    expect(result.isRunning).toBe(true);
  });

  it("agentEnd clears running/thinking/status", () => {
    const running = view({ isRunning: true, thinking: "deep thought", statusMessage: "working" });
    const result = applyAgentEvent(running, { type: "agentEnd" });
    expect(result.isRunning).toBe(false);
    expect(result.thinking).toBeNull();
    expect(result.statusMessage).toBeNull();
  });

  it("agentAbort clears running/thinking/status", () => {
    const result = applyAgentEvent(view({ isRunning: true, thinking: "x" }), {
      type: "agentAbort",
    });
    expect(result.isRunning).toBe(false);
    expect(result.thinking).toBeNull();
  });

  it("messageStart appends empty assistant message", () => {
    const result = applyAgentEvent(view(), { type: "messageStart" });
    expect(result.timeline).toHaveLength(1);
    expect(result.timeline[0]).toEqual({
      kind: "message",
      message: { role: "assistant", content: "" },
    });
  });

  it("messageDelta appends to last assistant message", () => {
    const v = view({
      timeline: [{ kind: "message", message: { role: "assistant", content: "Hello" } }],
    });
    const result = applyAgentEvent(v, { type: "messageDelta", delta: " world" });
    const last = result.timeline[result.timeline.length - 1];
    expect(last).toEqual({
      kind: "message",
      message: { role: "assistant", content: "Hello world" },
    });
  });

  it("messageDelta creates new message if last entry is not assistant message", () => {
    const v = view({
      timeline: [{ kind: "thinking", text: "hmm" }],
    });
    const result = applyAgentEvent(v, { type: "messageDelta", delta: "Hello" });
    expect(result.timeline).toHaveLength(2);
    expect(result.timeline[1]).toEqual({
      kind: "message",
      message: { role: "assistant", content: "Hello" },
    });
  });

  it("thinkingStart adds thinking entry", () => {
    const result = applyAgentEvent(view(), { type: "thinkingStart" });
    expect(result.thinking).toBe("");
    expect(result.timeline[0]).toEqual({ kind: "thinking", text: "" });
  });

  it("thinkingDelta appends to thinking", () => {
    const v = view({
      thinking: "part1",
      timeline: [{ kind: "thinking", text: "part1" }],
    });
    const result = applyAgentEvent(v, { type: "thinkingDelta", delta: "part2" });
    expect(result.thinking).toBe("part1part2");
    expect(result.timeline[0]).toEqual({ kind: "thinking", text: "part1part2" });
  });

  it("toolExecutionStart adds running tool", () => {
    const result = applyAgentEvent(view(), {
      type: "toolExecutionStart",
      tool: "read_file",
      callId: "call_1",
      args: { path: "/tmp" },
      meta: "reading /tmp",
    });
    expect(result.timeline).toHaveLength(1);
    const entry = result.timeline[0];
    expect(entry.kind).toBe("tool");
    if (entry.kind === "tool") {
      expect(entry.task.tool).toBe("read_file");
      expect(entry.task.status).toBe("running");
      expect(entry.task.callId).toBe("call_1");
    }
  });

  it("tool_execution_start handles snake_case call_id", () => {
    const result = applyAgentEvent(view(), {
      type: "tool_execution_start",
      tool: "shell",
      call_id: "call_2",
      args: {},
      meta: "",
    });
    const entry = result.timeline[0];
    if (entry.kind === "tool") {
      expect(entry.task.callId).toBe("call_2");
    }
  });

  it("toolExecutionEnd updates tool status to done", () => {
    const v = view({
      timeline: [
        {
          kind: "tool",
          task: { tool: "read_file", callId: "c1", args: {}, meta: "", status: "running" },
        },
      ],
    });
    const result = applyAgentEvent(v, {
      type: "toolExecutionEnd",
      callId: "c1",
      result: { ok: true, output: "content" },
    });
    const entry = result.timeline[0];
    if (entry.kind === "tool") {
      expect(entry.task.status).toBe("done");
      expect(entry.task.result?.ok).toBe(true);
    }
  });

  it("toolExecutionEnd sets status to error on failure", () => {
    const v = view({
      timeline: [
        {
          kind: "tool",
          task: { tool: "shell", callId: "c2", args: {}, meta: "", status: "running" },
        },
      ],
    });
    const result = applyAgentEvent(v, {
      type: "toolExecutionEnd",
      callId: "c2",
      result: { ok: false, error: "failed" },
    });
    const entry = result.timeline[0];
    if (entry.kind === "tool") {
      expect(entry.task.status).toBe("error");
    }
  });

  it("toolExecutionEnd with unknown callId is a no-op", () => {
    const v = view();
    const result = applyAgentEvent(v, {
      type: "toolExecutionEnd",
      callId: "unknown",
      result: { ok: true },
    });
    expect(result).toEqual(v);
  });

  it("statusUpdate sets statusMessage", () => {
    const result = applyAgentEvent(view(), { type: "statusUpdate", message: "Compacting..." });
    expect(result.statusMessage).toBe("Compacting...");
  });

  it("unknown event type is a no-op", () => {
    const v = view();
    const result = applyAgentEvent(v, { type: "somethingNew" });
    expect(result).toEqual(v);
  });
});

describe("applyEvent", () => {
  it("agentEnd updates tokenUsage", () => {
    const state = emptyState();
    const event: AgentEvent = {
      type: "agentEnd",
      usage: {
        promptTokens: 100,
        completionTokens: 50,
        totalTokens: 150,
        contextWindow: 128000,
        currentContextTokens: 200,
      },
    };
    const result = applyEvent(state, event);
    expect(result.tokenUsage).toEqual({
      promptTokens: 100,
      completionTokens: 50,
      totalTokens: 150,
      contextWindow: 128000,
      currentContextTokens: 200,
    });
    expect(result.subAgents).toEqual({});
    expect(result.activeTab).toBe("main");
  });

  it("agentEnd without usage preserves existing tokenUsage", () => {
    const state = {
      ...emptyState(),
      tokenUsage: {
        promptTokens: 10,
        completionTokens: 5,
        totalTokens: 15,
        contextWindow: 100000,
        currentContextTokens: 20,
      },
    };
    const result = applyEvent(state, { type: "agentEnd" } as AgentEvent);
    expect(result.tokenUsage).toEqual(state.tokenUsage);
  });

  it("agentAbort clears subAgents and resets tab", () => {
    const state = {
      ...emptyState(),
      subAgents: {
        sub1: {
          sessionId: "sub1",
          parentCallId: "c1",
          label: "test",
          model: "gpt-4",
          tools: [],
          timeline: [],
          thinking: null,
          statusMessage: null,
          isRunning: true,
          startedAt: 0,
          toolCount: 0,
        },
      },
      activeTab: "sub1",
    };
    const result = applyEvent(state, { type: "agentAbort" } as AgentEvent);
    expect(result.subAgents).toEqual({});
    expect(result.activeTab).toBe("main");
  });

  it("messageDelta updates lastDeltaAt", () => {
    const state = emptyState();
    state.main = view({
      timeline: [{ kind: "message", message: { role: "assistant", content: "" } }],
    });
    const before = Date.now();
    const result = applyEvent(state, { type: "messageDelta", delta: "x" } as AgentEvent);
    expect(result.lastDeltaAt).toBeGreaterThanOrEqual(before);
  });

  it("toolExecutionStart does not update lastDeltaAt", () => {
    const state = { ...emptyState(), lastDeltaAt: 0 };
    const result = applyEvent(state, {
      type: "toolExecutionStart",
      tool: "read_file",
      callId: "c1",
      args: {},
      meta: "",
    } as AgentEvent);
    expect(result.lastDeltaAt).toBe(0);
  });

  it("subAgentEvent/sub_agent_start creates SubAgent entry", () => {
    const state = emptyState();
    const event = {
      type: "subAgentEvent",
      parentCallId: "p1",
      subSessionId: "sub1",
      inner: {
        type: "sub_agent_start",
        label: "Research",
        model: "gpt-4",
        tools: ["read_file"],
      },
    } as unknown as AgentEvent;
    const result = applyEvent(state, event);
    expect(result.subAgents["sub1"]).toBeDefined();
    expect(result.subAgents["sub1"].label).toBe("Research");
    expect(result.subAgents["sub1"].isRunning).toBe(true);
  });

  it("subAgentEvent routes inner events to sub-agent", () => {
    const state = {
      ...emptyState(),
      subAgents: {
        sub1: {
          sessionId: "sub1",
          parentCallId: "p1",
          label: "test",
          model: "gpt-4",
          tools: [],
          timeline: [],
          thinking: null,
          statusMessage: null,
          isRunning: true,
          startedAt: 0,
          toolCount: 0,
        },
      },
    };
    const event = {
      type: "subAgentEvent",
      parentCallId: "p1",
      subSessionId: "sub1",
      inner: { type: "message_start" },
    } as unknown as AgentEvent;
    const result = applyEvent(state, event);
    expect(result.subAgents["sub1"].timeline).toHaveLength(1);
  });

  it("subAgentEvent/agent_end removes sub-agent", () => {
    const state = {
      ...emptyState(),
      subAgents: {
        sub1: {
          sessionId: "sub1",
          parentCallId: "p1",
          label: "test",
          model: "gpt-4",
          tools: [],
          timeline: [],
          thinking: null,
          statusMessage: null,
          isRunning: true,
          startedAt: 0,
          toolCount: 0,
        },
      },
      activeTab: "sub1",
    };
    const event = {
      type: "subAgentEvent",
      parentCallId: "p1",
      subSessionId: "sub1",
      inner: { type: "agent_end" },
    } as unknown as AgentEvent;
    const result = applyEvent(state, event);
    expect(result.subAgents["sub1"]).toBeUndefined();
    expect(result.activeTab).toBe("main");
  });

  it("subAgentEvent for unknown subSessionId is no-op", () => {
    const state = emptyState();
    const event = {
      type: "subAgentEvent",
      parentCallId: "p1",
      subSessionId: "unknown",
      inner: { type: "message_start" },
    } as unknown as AgentEvent;
    const result = applyEvent(state, event);
    expect(result).toEqual(state);
  });

  it("error sets error and stops running", () => {
    const state = { ...emptyState(), main: view({ isRunning: true }) };
    const result = applyEvent(state, { type: "error", reason: "API timeout" } as AgentEvent);
    expect(result.error).toBe("API timeout");
    expect(result.main.isRunning).toBe(false);
  });

  it("skillLoaded adds skill to timeline", () => {
    const result = applyEvent(emptyState(), {
      type: "skillLoaded",
      name: "git",
      description: "Git operations",
    } as AgentEvent);
    const last = result.main.timeline[result.main.timeline.length - 1];
    expect(last.kind).toBe("skill");
    if (last.kind === "skill") {
      expect(last.skill.name).toBe("git");
    }
  });

  it("contextDiscovered adds context to timeline", () => {
    const result = applyEvent(emptyState(), {
      type: "contextDiscovered",
      files: ["AGENTS.md"],
    } as AgentEvent);
    const last = result.main.timeline[result.main.timeline.length - 1];
    expect(last.kind).toBe("context");
    if (last.kind === "context") {
      expect(last.context.files).toEqual(["AGENTS.md"]);
    }
  });

  it("agentRecovered adds recovery message and clears error", () => {
    const state = { ...emptyState(), error: "Server died" };
    const result = applyEvent(state, { type: "agentRecovered" } as AgentEvent);
    expect(result.error).toBeNull();
    expect(result.main.isRunning).toBe(false);
    const last = result.main.timeline[result.main.timeline.length - 1];
    if (last.kind === "message") {
      expect(last.message.content).toContain("recovered");
    }
  });

  it("usageUpdate updates tokenUsage", () => {
    const usage = {
      promptTokens: 200,
      completionTokens: 100,
      totalTokens: 300,
      contextWindow: 128000,
      currentContextTokens: 400,
    };
    const result = applyEvent(emptyState(), {
      type: "usageUpdate",
      usage,
    } as AgentEvent);
    expect(result.tokenUsage).toEqual(usage);
  });

  it("turnEnd is a no-op", () => {
    const state = emptyState();
    const result = applyEvent(state, { type: "turnEnd", message: "done" } as AgentEvent);
    expect(result).toEqual(state);
  });

  it("unknown event type is a no-op", () => {
    const state = emptyState();
    const result = applyEvent(state, { type: "unknown" } as unknown as AgentEvent);
    expect(result).toEqual(state);
  });
});

describe("combineDeltas", () => {
  it("merges consecutive messageDelta events", () => {
    const events: AgentEvent[] = [
      { type: "messageDelta", delta: "Hello" },
      { type: "messageDelta", delta: " world" },
    ];
    const result = combineDeltas(events);
    expect(result).toHaveLength(1);
    expect((result[0] as { delta: string }).delta).toBe("Hello world");
  });

  it("merges consecutive thinkingDelta events", () => {
    const events: AgentEvent[] = [
      { type: "thinkingDelta", delta: "Think" },
      { type: "thinkingDelta", delta: "ing" },
    ];
    const result = combineDeltas(events);
    expect(result).toHaveLength(1);
    expect((result[0] as { delta: string }).delta).toBe("Thinking");
  });

  it("does not merge different event types", () => {
    const events: AgentEvent[] = [
      { type: "messageDelta", delta: "Hello" },
      { type: "thinkingDelta", delta: "Think" },
      { type: "messageDelta", delta: " world" },
    ];
    const result = combineDeltas(events);
    expect(result).toHaveLength(3);
  });

  it("returns empty array for empty input", () => {
    expect(combineDeltas([])).toEqual([]);
  });

  it("returns single event unchanged", () => {
    const events: AgentEvent[] = [{ type: "agentStart" }];
    expect(combineDeltas(events)).toHaveLength(1);
  });

  it("passes non-delta events through", () => {
    const events: AgentEvent[] = [
      { type: "agentStart" },
      { type: "messageDelta", delta: "a" },
      { type: "messageDelta", delta: "b" },
      { type: "agentEnd" },
    ];
    const result = combineDeltas(events);
    expect(result).toHaveLength(3);
    expect(result[0].type).toBe("agentStart");
    expect((result[1] as { delta: string }).delta).toBe("ab");
    expect(result[2].type).toBe("agentEnd");
  });
});
