/**
 * Test helpers — event factories for state tests.
 *
 * Thin wrappers that produce valid {@link AgentEvent} objects
 * with sensible defaults so tests stay concise.
 */

import type { AgentEvent } from "../../sdk/protocol.js";

export const ev = {
  agentStart: (): AgentEvent => ({ type: "agentStart" }) as AgentEvent,

  agentEnd: (usage?: {
    promptTokens: number;
    completionTokens: number;
    totalTokens: number;
    contextWindow: number;
    currentContextTokens: number;
  }): AgentEvent => ({ type: "agentEnd", usage }) as AgentEvent,

  agentAbort: (): AgentEvent =>
    ({ type: "agentAbort", reason: "user" }) as AgentEvent,

  agentRecovered: (): AgentEvent =>
    ({ type: "agentRecovered" }) as AgentEvent,

  messageStart: (): AgentEvent => ({ type: "messageStart" }) as AgentEvent,

  messageDelta: (delta: string): AgentEvent =>
    ({ type: "messageDelta", delta }) as AgentEvent,

  messageApplied: (text: string): AgentEvent =>
    ({ type: "messageApplied", text }) as AgentEvent,

  messageQueued: (text: string): AgentEvent =>
    ({ type: "messageQueued", text }) as AgentEvent,

  thinkingStart: (): AgentEvent => ({ type: "thinkingStart" }) as AgentEvent,

  thinkingDelta: (delta: string): AgentEvent =>
    ({ type: "thinkingDelta", delta }) as AgentEvent,

  toolStart: (
    tool: string,
    callId: string,
    args: Record<string, unknown> = {},
    meta = "",
  ): AgentEvent =>
    ({ type: "toolExecutionStart", tool, callId, args, meta }) as AgentEvent,

  toolEnd: (
    tool: string,
    callId: string,
    ok = true,
    output?: unknown,
  ): AgentEvent =>
    ({
      type: "toolExecutionEnd",
      tool,
      callId,
      result: { ok, output },
    }) as AgentEvent,

  skillLoaded: (name: string, description = ""): AgentEvent =>
    ({ type: "skillLoaded", name, description }) as AgentEvent,

  contextDiscovered: (files: string[]): AgentEvent =>
    ({ type: "contextDiscovered", files }) as AgentEvent,

  statusUpdate: (message: string): AgentEvent =>
    ({ type: "statusUpdate", message }) as AgentEvent,

  usageUpdate: (usage: {
    promptTokens: number;
    completionTokens: number;
    totalTokens: number;
    contextWindow: number;
    currentContextTokens: number;
  }): AgentEvent => ({ type: "usageUpdate", usage }) as AgentEvent,

  error: (reason: string): AgentEvent =>
    ({ type: "error", reason }) as AgentEvent,

  subAgentEvent: (
    subSessionId: string,
    parentCallId: string,
    inner: Record<string, unknown>,
  ): AgentEvent =>
    ({
      type: "subAgentEvent",
      subSessionId,
      parentCallId,
      inner,
    }) as AgentEvent,

  turnEnd: (message = ""): AgentEvent =>
    ({ type: "turnEnd", message }) as AgentEvent,
};
