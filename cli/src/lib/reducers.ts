// Extracted from hooks/use-opal.ts for testability
import type { AgentEvent, TokenUsage } from "../sdk/protocol.js";

/** A backend message from session/history. */
export interface HistoryMessage {
  id: string;
  role: string;
  content?: string | null;
  thinking?: string | null;
  toolCalls?: { callId: string; name: string; arguments: Record<string, unknown> }[];
  callId?: string;
  name?: string;
  isError?: boolean;
  metadata?: Record<string, unknown>;
}

export interface Message {
  role: "user" | "assistant";
  content: string;
}

export interface Task {
  tool: string;
  callId: string;
  args: Record<string, unknown>;
  meta: string;
  status: "running" | "done" | "error";
  result?: { ok: boolean; output?: unknown; error?: string };
}

export interface Skill {
  name: string;
  description: string;
  status: "loaded";
}

export interface Context {
  files: string[];
  skills: string[];
  mcpServers: string[];
  distribution?: { node: string; cookie: string };
  status: "discovered";
}

export type TimelineEntry =
  | { kind: "message"; message: Message }
  | { kind: "tool"; task: Task }
  | { kind: "skill"; skill: Skill }
  | { kind: "context"; context: Context }
  | { kind: "thinking"; text: string };

export interface AgentView {
  timeline: TimelineEntry[];
  thinking: string | null;
  statusMessage: string | null;
  isRunning: boolean;
}

export interface SubAgent extends AgentView {
  sessionId: string;
  parentCallId: string;
  label: string;
  model: string;
  tools: string[];
  startedAt: number;
  toolCount: number;
}

/** Minimal state shape required by the reducers. Compatible with the full OpalState in use-opal.ts. */
export interface ReducerState {
  main: AgentView;
  subAgents: Record<string, SubAgent>;
  activeTab: string;
  tokenUsage: TokenUsage | null;
  error: string | null;
  lastDeltaAt: number;
  queuedMessages: string[];
}

export function emptyAgentView(): AgentView {
  return { timeline: [], thinking: null, statusMessage: null, isRunning: false };
}

export function emptyState(): ReducerState {
  return {
    main: emptyAgentView(),
    subAgents: {},
    activeTab: "main",
    tokenUsage: null,
    error: null,
    lastDeltaAt: 0,
    queuedMessages: [],
  };
}

/** Apply an agent-level event to an AgentView. Shared by main and sub-agents. */
export function applyAgentEvent(view: AgentView, event: Record<string, unknown>): AgentView {
  const type = event.type as string;
  switch (type) {
    case "agentStart":
    case "agent_start":
      return { ...view, isRunning: true };

    case "agentEnd":
    case "agent_end":
      return { ...view, isRunning: false, thinking: null, statusMessage: null };

    case "agentAbort":
    case "agent_abort":
      return { ...view, isRunning: false, thinking: null, statusMessage: null };

    case "messageStart":
    case "message_start":
      return {
        ...view,
        timeline: view.timeline.concat({
          kind: "message",
          message: { role: "assistant", content: "" },
        }),
      };

    case "messageDelta":
    case "message_delta":
      return {
        ...view,
        timeline: appendMessageDelta(view.timeline, (event.delta as string) ?? ""),
      };

    case "thinkingStart":
    case "thinking_start":
      return {
        ...view,
        thinking: "",
        timeline: view.timeline.concat({ kind: "thinking", text: "" }),
      };

    case "thinkingDelta":
    case "thinking_delta": {
      const delta = (event.delta as string) ?? "";
      return {
        ...view,
        thinking: (view.thinking ?? "") + delta,
        timeline: appendThinkingDelta(view.timeline, delta),
      };
    }

    case "toolExecutionStart":
    case "tool_execution_start":
      return {
        ...view,
        timeline: view.timeline.concat({
          kind: "tool",
          task: {
            tool: (event.tool as string) ?? "",
            callId: ((event.callId ?? event.call_id) as string) ?? "",
            args: (event.args as Record<string, unknown>) ?? {},
            meta: (event.meta as string) ?? "",
            status: "running",
          },
        }),
      };

    case "toolExecutionEnd":
    case "tool_execution_end": {
      const callId = ((event.callId ?? event.call_id) as string) ?? "";
      const result = event.result as { ok: boolean; output?: unknown; error?: string };
      const idx = view.timeline.findIndex((e) => e.kind === "tool" && e.task.callId === callId);
      if (idx >= 0) {
        const entry = view.timeline[idx] as { kind: "tool"; task: Task };
        const updated = view.timeline.slice();
        updated[idx] = {
          kind: "tool",
          task: {
            ...entry.task,
            status: (result.ok ? "done" : "error") as Task["status"],
            result,
          },
        };
        return { ...view, timeline: updated };
      }
      return view;
    }

    case "statusUpdate":
    case "status_update":
      return { ...view, statusMessage: (event.message as string) ?? null };

    default:
      return view;
  }
}

export function applyEvent<S extends ReducerState>(state: S, event: AgentEvent): S {
  const e = event as unknown as Record<string, unknown>;
  switch (event.type) {
    case "agentStart":
      return { ...state, main: applyAgentEvent(state.main, e) };

    case "agentEnd":
      return {
        ...state,
        main: applyAgentEvent(state.main, e),
        subAgents: {},
        activeTab: "main",
        tokenUsage: event.usage
          ? {
              promptTokens: event.usage.promptTokens,
              completionTokens: event.usage.completionTokens,
              totalTokens: event.usage.totalTokens,
              contextWindow: event.usage.contextWindow,
              currentContextTokens: event.usage.currentContextTokens,
            }
          : state.tokenUsage,
      };

    case "agentAbort":
      return { ...state, main: applyAgentEvent(state.main, e), subAgents: {}, activeTab: "main" };

    case "messageStart":
    case "messageDelta":
    case "thinkingStart":
    case "thinkingDelta":
    case "toolExecutionStart":
    case "statusUpdate":
      return {
        ...state,
        main: applyAgentEvent(state.main, e),
        lastDeltaAt: event.type === "messageDelta" ? Date.now() : state.lastDeltaAt,
      };

    case "toolExecutionEnd":
      return { ...state, main: applyAgentEvent(state.main, e) };

    case "subAgentEvent": {
      const inner = event.inner;
      const innerType = inner.type as string | undefined;
      const subSessionId = event.subSessionId;
      const parentCallId = event.parentCallId;

      if (innerType === "sub_agent_start") {
        const sub: SubAgent = {
          sessionId: subSessionId,
          parentCallId,
          label: (inner.label as string) ?? "",
          model: (inner.model as string) ?? "",
          tools: (inner.tools as string[]) ?? [],
          timeline: [],
          thinking: null,
          statusMessage: null,
          isRunning: true,
          startedAt: Date.now(),
          toolCount: 0,
        };
        return { ...state, subAgents: { ...state.subAgents, [subSessionId]: sub } };
      }

      const existing = state.subAgents[subSessionId];
      if (!existing) return state;

      const updatedView = applyAgentEvent(
        existing,
        inner as { type: string; [k: string]: unknown },
      );

      let toolCount = existing.toolCount;
      if (innerType === "tool_execution_start") toolCount++;

      const isDone = innerType === "agent_end";
      const updatedSub: SubAgent = { ...existing, ...updatedView, toolCount, isRunning: !isDone };

      let nextSubAgents: Record<string, SubAgent>;
      let nextTab = state.activeTab;
      if (isDone) {
        nextSubAgents = { ...state.subAgents };
        delete nextSubAgents[subSessionId];
        if (nextTab === subSessionId) nextTab = "main";
      } else {
        nextSubAgents = { ...state.subAgents, [subSessionId]: updatedSub };
      }

      return { ...state, subAgents: nextSubAgents, activeTab: nextTab };
    }

    case "messageApplied": {
      const text = (event as unknown as { text: string }).text;
      // Remove the first matching queued message
      const idx = state.queuedMessages.indexOf(text);
      const nextQueued =
        idx >= 0
          ? [...state.queuedMessages.slice(0, idx), ...state.queuedMessages.slice(idx + 1)]
          : state.queuedMessages;
      return {
        ...state,
        queuedMessages: nextQueued,
        main: {
          ...state.main,
          timeline: state.main.timeline.concat({
            kind: "message",
            message: { role: "user", content: text },
          }),
        },
      };
    }

    case "turnEnd":
      return state;

    case "error":
      return { ...state, main: { ...state.main, isRunning: false }, error: event.reason };

    case "skillLoaded":
      return {
        ...state,
        main: {
          ...state.main,
          timeline: state.main.timeline.concat({
            kind: "skill",
            skill: { name: event.name, description: event.description, status: "loaded" },
          }),
        },
      };

    case "contextDiscovered":
      return {
        ...state,
        main: {
          ...state.main,
          timeline: state.main.timeline.concat({
            kind: "context",
            context: { files: event.files, skills: [], mcpServers: [], status: "discovered" },
          }),
        },
      };

    case "agentRecovered":
      return {
        ...state,
        main: {
          ...state.main,
          isRunning: false,
          timeline: state.main.timeline.concat({
            kind: "message",
            message: {
              role: "assistant",
              content: "⚠ Agent crashed and recovered — conversation history preserved.",
            },
          }),
        },
        error: null,
      };

    case "usageUpdate":
      return {
        ...state,
        tokenUsage: event.usage
          ? {
              promptTokens: event.usage.promptTokens,
              completionTokens: event.usage.completionTokens,
              totalTokens: event.usage.totalTokens,
              contextWindow: event.usage.contextWindow,
              currentContextTokens: event.usage.currentContextTokens,
            }
          : state.tokenUsage,
      };

    default:
      return state;
  }
}

function appendMessageDelta(timeline: TimelineEntry[], delta: string): TimelineEntry[] {
  const last = timeline[timeline.length - 1];
  if (last?.kind === "message" && last.message.role === "assistant") {
    const updated = timeline.slice();
    updated[timeline.length - 1] = {
      kind: "message",
      message: { role: "assistant", content: last.message.content + delta },
    };
    return updated;
  }
  return [...timeline, { kind: "message", message: { role: "assistant", content: delta } }];
}

function appendThinkingDelta(timeline: TimelineEntry[], delta: string): TimelineEntry[] {
  const last = timeline[timeline.length - 1];
  if (last?.kind === "thinking") {
    const updated = timeline.slice();
    updated[timeline.length - 1] = { kind: "thinking", text: last.text + delta };
    return updated;
  }
  return [...timeline, { kind: "thinking", text: delta }];
}

export function combineDeltas(events: AgentEvent[]): AgentEvent[] {
  const out: AgentEvent[] = [];
  for (const ev of events) {
    if (ev.type === "messageDelta" || ev.type === "thinkingDelta") {
      const prev = out[out.length - 1];
      if (prev && prev.type === ev.type) {
        (prev as { delta?: string }).delta =
          ((prev as { delta?: string }).delta ?? "") + ((ev as { delta?: string }).delta ?? "");
        continue;
      }
    }
    out.push(ev);
  }
  return out;
}

/**
 * Transform backend session/history messages into TimelineEntry[].
 *
 * Skips system messages and maps user, assistant, tool_call, and tool_result
 * into the timeline model displayed in the CLI.
 */
export function historyToTimeline(messages: HistoryMessage[]): TimelineEntry[] {
  const timeline: TimelineEntry[] = [];

  // Build a lookup from call_id → tool_result for pairing
  const resultByCallId = new Map<string, HistoryMessage>();
  for (const msg of messages) {
    if (msg.role === "tool_result" && msg.callId) {
      resultByCallId.set(msg.callId, msg);
    }
  }

  for (const msg of messages) {
    switch (msg.role) {
      case "system":
        // Skip system prompt in the restored timeline
        break;

      case "user":
        if (msg.content) {
          timeline.push({
            kind: "message",
            message: { role: "user", content: msg.content },
          });
        }
        break;

      case "assistant": {
        // If there's thinking, add as a separate entry
        if (msg.thinking) {
          timeline.push({ kind: "thinking", text: msg.thinking });
        }

        // Add tool calls as tool entries (paired with results)
        if (msg.toolCalls) {
          for (const tc of msg.toolCalls) {
            const result = resultByCallId.get(tc.callId);
            const task: Task = {
              tool: tc.name,
              callId: tc.callId,
              args: tc.arguments,
              meta: "",
              status: result ? (result.isError ? "error" : "done") : "done",
              result: result
                ? {
                    ok: !result.isError,
                    output: result.content,
                    error: result.isError ? (result.content ?? undefined) : undefined,
                  }
                : undefined,
            };
            timeline.push({ kind: "tool", task });
          }
        }

        // Add assistant text if present
        if (msg.content) {
          timeline.push({
            kind: "message",
            message: { role: "assistant", content: msg.content },
          });
        }
        break;
      }

      case "tool_call": {
        // tool_call messages are standalone (some providers use this format)
        const callId = msg.callId ?? "";
        const result = resultByCallId.get(callId);
        const args = msg.content ? tryParseJson(msg.content) : {};
        const task: Task = {
          tool: msg.name ?? "",
          callId,
          args,
          meta: "",
          status: result ? (result.isError ? "error" : "done") : "done",
          result: result
            ? {
                ok: !result.isError,
                output: result.content,
                error: result.isError ? (result.content ?? undefined) : undefined,
              }
            : undefined,
        };
        timeline.push({ kind: "tool", task });
        break;
      }

      case "tool_result":
        // Already paired with tool_call/assistant above — skip
        break;
    }
  }

  return timeline;
}

function tryParseJson(s: string): Record<string, unknown> {
  try {
    return JSON.parse(s) as Record<string, unknown>;
  } catch {
    return {};
  }
}
