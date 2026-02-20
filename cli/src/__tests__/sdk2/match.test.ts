import { describe, expect, it } from "vitest";
import type { AgentEvent } from "../../sdk/protocol.js";
import { isEventType, matchEvent, matchEventPartial, assertNever } from "../../sdk/match.js";

const delta = { type: "messageDelta" as const, delta: "hello" } as AgentEvent;
const start = { type: "agentStart" as const } as AgentEvent;
const toolStart = {
  type: "toolExecutionStart" as const,
  tool: "shell",
  callId: "c1",
  args: {},
  meta: "run",
} as AgentEvent;

describe("isEventType", () => {
  it("returns true for matching type", () => {
    expect(isEventType(delta, "messageDelta")).toBe(true);
  });

  it("returns false for non-matching type", () => {
    expect(isEventType(delta, "agentStart")).toBe(false);
  });
});

describe("matchEvent", () => {
  it("calls the correct handler for the event type", () => {
    const allHandlers = Object.fromEntries(
      [
        "agentAbort",
        "agentEnd",
        "agentRecovered",
        "agentStart",
        "contextDiscovered",
        "error",
        "messageApplied",
        "messageDelta",
        "messageQueued",
        "messageStart",
        "skillLoaded",
        "statusUpdate",
        "subAgentEvent",
        "thinkingDelta",
        "thinkingStart",
        "toolExecutionEnd",
        "toolExecutionStart",
        "turnEnd",
        "usageUpdate",
      ].map((t) => [t, () => "other"]),
    );
    allHandlers.messageDelta = (e: AgentEvent) =>
      "type" in e && e.type === "messageDelta" ? (e as { delta: string }).delta : "";
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    expect(matchEvent(delta, allHandlers as any)).toBe("hello");
    allHandlers.agentStart = () => "started";
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    expect(matchEvent(start, allHandlers as any)).toBe("started");
  });
});

describe("matchEventPartial", () => {
  it("calls specific handler when available", () => {
    const result = matchEventPartial(toolStart, {
      toolExecutionStart: (e) => e.tool,
      _: () => "default",
    });
    expect(result).toBe("shell");
  });

  it("falls through to _ default for unhandled types", () => {
    const result = matchEventPartial(start, {
      messageDelta: () => "delta",
      _: () => "default",
    });
    expect(result).toBe("default");
  });
});

describe("assertNever", () => {
  it("throws an error", () => {
    expect(() => assertNever("unexpected" as never)).toThrow("Unexpected value");
  });
});
