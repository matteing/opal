import { describe, it, expect } from "vitest";
import { applyEvent, ROOT_AGENT_ID } from "../../state/timeline.js";
import type { TimelineSnapshot } from "../../state/timeline.js";
import type { AgentView } from "../../state/types.js";
import { ev } from "./helpers.js";

// Fresh initial state for each test
function initial(): TimelineSnapshot {
  const root: AgentView = {
    id: ROOT_AGENT_ID,
    parentCallId: null,
    label: "Opal",
    model: "",
    tools: [],
    entries: [],
    thinking: null,
    statusMessage: null,
    isRunning: false,
    startedAt: 0,
    toolCount: 0,
  };
  return {
    agents: { [ROOT_AGENT_ID]: root } as Readonly<Record<string, AgentView>>,
    focusStack: [ROOT_AGENT_ID] as readonly string[],
    tokenUsage: null,
    queuedMessages: [] as readonly string[],
    timelineError: null,
  };
}

/** Shorthand: root agent from state. */
function root(state: ReturnType<typeof initial>) {
  return state.agents[ROOT_AGENT_ID];
}

/** Apply a sequence of events and return final state. */
function apply(...events: ReturnType<(typeof ev)[keyof typeof ev]>[]) {
  let state = initial();
  for (const event of events) {
    state = applyEvent(state, event);
  }
  return state;
}

// ── agentStart / agentEnd ────────────────────────────────────────

describe("applyEvent — lifecycle", () => {
  it("agentStart sets isRunning to true", () => {
    const state = apply(ev.agentStart());
    expect(root(state).isRunning).toBe(true);
  });

  it("agentEnd sets isRunning to false and clears thinking", () => {
    const state = apply(
      ev.agentStart(),
      ev.thinkingStart(),
      ev.thinkingDelta("hmm"),
      ev.agentEnd(),
    );
    expect(root(state).isRunning).toBe(false);
    expect(root(state).thinking).toBeNull();
    expect(root(state).statusMessage).toBeNull();
  });

  it("agentEnd records token usage when present", () => {
    const usage = {
      promptTokens: 100,
      completionTokens: 50,
      totalTokens: 150,
      contextWindow: 128_000,
      currentContextTokens: 1200,
    };
    const state = apply(ev.agentStart(), ev.agentEnd(usage));
    expect(state.tokenUsage).toEqual(usage);
  });

  it("agentEnd preserves prior token usage when event has none", () => {
    const usage = {
      promptTokens: 100,
      completionTokens: 50,
      totalTokens: 150,
      contextWindow: 128_000,
      currentContextTokens: 1200,
    };
    const state = apply(ev.agentStart(), ev.agentEnd(usage), ev.agentStart(), ev.agentEnd());
    expect(state.tokenUsage).toEqual(usage);
  });

  it("agentAbort clears sub-agents", () => {
    const state = apply(
      ev.agentStart(),
      ev.subAgentEvent("sub1", "c1", {
        type: "sub_agent_start",
        label: "worker",
        model: "gpt-4",
        tools: [],
      }),
      ev.agentAbort(),
    );
    expect(root(state).isRunning).toBe(false);
    // Only root remains
    expect(Object.keys(state.agents)).toEqual([ROOT_AGENT_ID]);
  });
});

// ── Messages ─────────────────────────────────────────────────────

describe("applyEvent — messages", () => {
  it("messageStart + deltas build an assistant message", () => {
    const state = apply(
      ev.agentStart(),
      ev.messageStart(),
      ev.messageDelta("Hello"),
      ev.messageDelta(" world"),
    );

    const entries = root(state).entries;
    expect(entries).toHaveLength(1);
    expect(entries[0]).toEqual({
      kind: "message",
      message: { role: "assistant", content: "Hello world" },
    });
  });

  it("messageApplied adds a user message and dequeues", () => {
    const state = apply(ev.messageQueued("fix tests"), ev.messageApplied("fix tests"));
    const entries = root(state).entries;
    expect(entries).toHaveLength(1);
    expect(entries[0]).toEqual({
      kind: "message",
      message: { role: "user", content: "fix tests" },
    });
    expect(state.queuedMessages).toEqual([]);
  });

  it("messageApplied with no matching queue leaves queue unchanged", () => {
    const state = apply(ev.messageQueued("other"), ev.messageApplied("fix tests"));
    expect(state.queuedMessages).toEqual(["other"]);
  });

  it("messageQueued appends to the queue", () => {
    const state = apply(ev.messageQueued("first"), ev.messageQueued("second"));
    expect(state.queuedMessages).toEqual(["first", "second"]);
  });
});

// ── Thinking ─────────────────────────────────────────────────────

describe("applyEvent — thinking", () => {
  it("thinkingStart + deltas build a thinking entry", () => {
    const state = apply(
      ev.agentStart(),
      ev.thinkingStart(),
      ev.thinkingDelta("Let me think"),
      ev.thinkingDelta("..."),
    );

    expect(root(state).thinking).toBe("Let me think...");
    const thinkingEntry = root(state).entries.find((e) => e.kind === "thinking");
    expect(thinkingEntry).toEqual({ kind: "thinking", text: "Let me think..." });
  });
});

// ── Tools ────────────────────────────────────────────────────────

describe("applyEvent — tools", () => {
  it("toolExecutionStart creates a running tool entry", () => {
    const state = apply(
      ev.agentStart(),
      ev.toolStart("shell", "c1", { command: "ls" }, "listing files"),
    );

    const entries = root(state).entries;
    expect(entries).toHaveLength(1);
    const entry = entries[0];
    expect(entry.kind).toBe("tool");
    if (entry.kind === "tool") {
      expect(entry.tool.tool).toBe("shell");
      expect(entry.tool.callId).toBe("c1");
      expect(entry.tool.status).toBe("running");
    }
  });

  it("toolExecutionEnd updates tool status to done", () => {
    const state = apply(
      ev.agentStart(),
      ev.toolStart("shell", "c1"),
      ev.toolEnd("shell", "c1", true, "file.txt"),
    );

    const entry = root(state).entries[0];
    if (entry.kind === "tool") {
      expect(entry.tool.status).toBe("done");
      expect(entry.tool.result).toEqual({ ok: true, output: "file.txt" });
    }
  });

  it("toolExecutionEnd with failure sets status to error", () => {
    const state = apply(
      ev.agentStart(),
      ev.toolStart("shell", "c1"),
      ev.toolEnd("shell", "c1", false),
    );

    const entry = root(state).entries[0];
    if (entry.kind === "tool") {
      expect(entry.tool.status).toBe("error");
    }
  });
});

// ── Skills & Context ─────────────────────────────────────────────

describe("applyEvent — skills & context", () => {
  it("skillLoaded adds a skill entry", () => {
    const state = apply(ev.skillLoaded("git", "Git integration"));
    const entries = root(state).entries;
    expect(entries).toHaveLength(1);
    expect(entries[0]).toEqual({
      kind: "skill",
      skill: { name: "git", description: "Git integration" },
    });
  });

  it("contextDiscovered adds a context entry", () => {
    const state = apply(ev.contextDiscovered(["AGENTS.md", ".opal/config"]));
    const entries = root(state).entries;
    expect(entries).toHaveLength(1);
    expect(entries[0]).toEqual({
      kind: "context",
      context: { files: ["AGENTS.md", ".opal/config"] },
    });
  });
});

// ── Sub-agents ───────────────────────────────────────────────────

describe("applyEvent — sub-agents", () => {
  it("sub_agent_start creates a new agent in the map", () => {
    const state = apply(
      ev.agentStart(),
      ev.subAgentEvent("sub1", "c1", {
        type: "sub_agent_start",
        label: "researcher",
        model: "gpt-4",
        tools: ["grep", "read_file"],
      }),
    );

    expect(state.agents).toHaveProperty("sub1");
    const sub = state.agents.sub1;
    expect(sub.label).toBe("researcher");
    expect(sub.model).toBe("gpt-4");
    expect(sub.isRunning).toBe(true);
    expect(sub.entries).toEqual([]);
    expect(sub.parentCallId).toBe("c1");
  });

  it("sub-agent events build the sub-agent's entries", () => {
    const state = apply(
      ev.agentStart(),
      ev.subAgentEvent("sub1", "c1", {
        type: "sub_agent_start",
        label: "worker",
        model: "gpt-4",
        tools: [],
      }),
      ev.subAgentEvent("sub1", "c1", { type: "messageStart" }),
      ev.subAgentEvent("sub1", "c1", { type: "messageDelta", delta: "Hi" }),
    );

    const sub = state.agents.sub1;
    expect(sub.entries).toHaveLength(1);
    expect(sub.entries[0]).toEqual({
      kind: "message",
      message: { role: "assistant", content: "Hi" },
    });
  });

  it("agent_end removes the sub-agent from the map", () => {
    const state = apply(
      ev.agentStart(),
      ev.subAgentEvent("sub1", "c1", {
        type: "sub_agent_start",
        label: "worker",
        model: "gpt-4",
        tools: [],
      }),
      ev.subAgentEvent("sub1", "c1", { type: "agent_end" }),
    );
    expect(state.agents).not.toHaveProperty("sub1");
  });

  it("toolExecutionStart increments sub-agent toolCount", () => {
    const state = apply(
      ev.agentStart(),
      ev.subAgentEvent("sub1", "c1", {
        type: "sub_agent_start",
        label: "worker",
        model: "gpt-4",
        tools: [],
      }),
      ev.subAgentEvent("sub1", "c1", {
        type: "toolExecutionStart",
        tool: "grep",
        callId: "tc1",
        args: {},
        meta: "",
      }),
    );
    expect(state.agents.sub1.toolCount).toBe(1);
  });

  it("agent_end auto-pops focus if sub-agent was focused", () => {
    let state = initial();
    state = applyEvent(state, ev.agentStart());
    state = applyEvent(
      state,
      ev.subAgentEvent("sub1", "c1", {
        type: "sub_agent_start",
        label: "worker",
        model: "gpt-4",
        tools: [],
      }),
    );
    // Simulate focus on sub-agent
    state = { ...state, focusStack: [ROOT_AGENT_ID, "sub1"] };
    state = applyEvent(state, ev.subAgentEvent("sub1", "c1", { type: "agent_end" }));

    expect(state.focusStack).toEqual([ROOT_AGENT_ID]);
    expect(state.agents).not.toHaveProperty("sub1");
  });
});

// ── Status, errors, recovery ─────────────────────────────────────

describe("applyEvent — status & errors", () => {
  it("statusUpdate sets statusMessage", () => {
    const state = apply(ev.agentStart(), ev.statusUpdate("thinking..."));
    expect(root(state).statusMessage).toBe("thinking...");
  });

  it("error sets isRunning=false and records error", () => {
    const state = apply(ev.agentStart(), ev.error("out of tokens"));
    expect(root(state).isRunning).toBe(false);
    expect(state.timelineError).toBe("out of tokens");
  });

  it("agentRecovered adds a recovery message", () => {
    const state = apply(ev.agentStart(), ev.agentRecovered());
    expect(root(state).isRunning).toBe(false);
    expect(root(state).entries).toHaveLength(1);
    expect(root(state).entries[0]).toEqual({
      kind: "message",
      message: {
        role: "assistant",
        content: "⚠ Agent crashed and recovered — conversation history preserved.",
      },
    });
  });

  it("usageUpdate replaces token usage", () => {
    const usage = {
      promptTokens: 200,
      completionTokens: 80,
      totalTokens: 280,
      contextWindow: 128_000,
      currentContextTokens: 2000,
    };
    const state = apply(ev.usageUpdate(usage));
    expect(state.tokenUsage).toEqual(usage);
  });
});

// ── turnEnd (no-op) ──────────────────────────────────────────────

describe("applyEvent — turnEnd", () => {
  it("turnEnd is a no-op", () => {
    const before = initial();
    const after = applyEvent(before, ev.turnEnd("done"));
    expect(after).toEqual(before);
  });
});

// ── Full conversation flow ───────────────────────────────────────

describe("applyEvent — full conversation", () => {
  it("models a complete prompt → response → tool → response cycle", () => {
    const state = apply(
      ev.messageApplied("list files"),
      ev.agentStart(),
      ev.messageStart(),
      ev.messageDelta("Let me "),
      ev.messageDelta("check."),
      ev.toolStart("shell", "c1", { command: "ls" }, "listing files"),
      ev.toolEnd("shell", "c1", true, "src/\nlib/"),
      ev.messageStart(),
      ev.messageDelta("Found: src/, lib/"),
      ev.agentEnd({
        promptTokens: 100,
        completionTokens: 50,
        totalTokens: 150,
        contextWindow: 128_000,
        currentContextTokens: 200,
      }),
    );

    const entries = root(state).entries;
    expect(entries).toHaveLength(4);
    expect(entries[0]).toEqual({
      kind: "message",
      message: { role: "user", content: "list files" },
    });
    expect(entries[1]).toEqual({
      kind: "message",
      message: { role: "assistant", content: "Let me check." },
    });
    expect(entries[2].kind).toBe("tool");
    expect(entries[3]).toEqual({
      kind: "message",
      message: { role: "assistant", content: "Found: src/, lib/" },
    });
    expect(root(state).isRunning).toBe(false);
    expect(state.tokenUsage?.totalTokens).toBe(150);
  });
});
