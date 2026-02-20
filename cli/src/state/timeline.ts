/**
 * Timeline slice — normalized agent views with focus-stack navigation.
 *
 * Every agent (root + sub-agents) is stored as an {@link AgentView} in a
 * single `agents` map keyed by ID. The root agent always lives at `"root"`.
 * Sub-agents are added/removed dynamically as `subAgentEvent` envelopes
 * arrive from the protocol.
 *
 * A focus stack (`focusStack`) tracks which agent the UI is viewing.
 * Components read from the focused agent via selectors — they never need
 * to know whether they're rendering the root agent or a sub-agent.
 *
 * @module
 */

import type { StateCreator } from "zustand";
import type {
  AgentEvent,
  ToolExecutionStartEvent,
  ToolExecutionEndEvent,
} from "../sdk/protocol.js";
import type { TimelineEntry, ToolCall, AgentView, TokenUsage, StatusLevel } from "./types.js";

// ── Constants ────────────────────────────────────────────────────

/** The root agent's ID in the agents map. */
export const ROOT_AGENT_ID = "root";

// ── Slice state + actions ────────────────────────────────────────

export interface TimelineSlice {
  /** All agent views, keyed by ID. Root agent is always `"root"`. */
  agents: Readonly<Record<string, AgentView>>;
  /** Navigation stack — last element is the focused agent. Starts as `["root"]`. */
  focusStack: readonly string[];
  tokenUsage: TokenUsage | null;
  queuedMessages: readonly string[];
  timelineError: string | null;

  /** Apply a batch of agent events to the timeline. */
  applyEvents: (events: readonly AgentEvent[]) => void;
  /** Push an agent onto the focus stack (navigate into a sub-agent). */
  focusAgent: (id: string) => void;
  /** Pop the focus stack (navigate back to the parent). */
  focusBack: () => void;
  /** Reset the timeline to initial state. */
  resetTimeline: () => void;
  /** Push a system status entry into the focused agent's timeline. */
  pushStatus: (text: string, level?: StatusLevel) => void;
}

// ── Root agent factory ───────────────────────────────────────────

function rootAgent(): AgentView {
  return {
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
}

// ── Snapshot (internal reducer state) ────────────────────────────

export interface TimelineSnapshot {
  agents: Readonly<Record<string, AgentView>>;
  focusStack: readonly string[];
  tokenUsage: TokenUsage | null;
  queuedMessages: readonly string[];
  timelineError: string | null;
}

const TIMELINE_INITIAL: TimelineSnapshot = {
  agents: { [ROOT_AGENT_ID]: rootAgent() },
  focusStack: [ROOT_AGENT_ID],
  tokenUsage: null,
  queuedMessages: [],
  timelineError: null,
};

// ── Pure helpers ─────────────────────────────────────────────────

function appendMessageDelta(entries: readonly TimelineEntry[], delta: string): TimelineEntry[] {
  const last = entries[entries.length - 1];
  if (last?.kind === "message" && last.message.role === "assistant") {
    const updated = entries.slice();
    updated[entries.length - 1] = {
      kind: "message",
      message: { role: "assistant", content: last.message.content + delta },
    };
    return updated;
  }
  return [...entries, { kind: "message", message: { role: "assistant", content: delta } }];
}

function appendThinkingDelta(entries: readonly TimelineEntry[], delta: string): TimelineEntry[] {
  const last = entries[entries.length - 1];
  if (last?.kind === "thinking") {
    const updated = entries.slice();
    updated[entries.length - 1] = { kind: "thinking", text: last.text + delta };
    return updated;
  }
  return [...entries, { kind: "thinking", text: delta }];
}

function updateToolEntry(
  entries: readonly TimelineEntry[],
  callId: string,
  patch: Partial<ToolCall> | ((tool: ToolCall) => Partial<ToolCall>),
): TimelineEntry[] {
  const idx = entries.findIndex((e) => e.kind === "tool" && e.tool.callId === callId);
  if (idx < 0) return entries as TimelineEntry[];
  const entry = entries[idx] as { kind: "tool"; tool: ToolCall };
  const resolved = typeof patch === "function" ? patch(entry.tool) : patch;
  const updated = entries.slice();
  updated[idx] = { kind: "tool", tool: { ...entry.tool, ...resolved } };
  return updated;
}

// ── View-level reducer (shared across all agents) ────────────────

interface ViewFields {
  entries: readonly TimelineEntry[];
  thinking: string | null;
  statusMessage: string | null;
  isRunning: boolean;
}

function reduceView(view: ViewFields, event: Record<string, unknown>): ViewFields {
  const type = event.type as string;

  switch (type) {
    case "agentStart":
      return { ...view, isRunning: true };

    case "agentEnd":
    case "agentAbort":
      return { ...view, thinking: null, statusMessage: null, isRunning: false };

    case "messageStart": {
      // Deduplicate: if the last entry is already an empty assistant message,
      // don't add another (guards against providers that emit multiple
      // text_start events per response).
      const last = view.entries[view.entries.length - 1];
      if (
        last?.kind === "message" &&
        last.message.role === "assistant" &&
        last.message.content === ""
      ) {
        return view;
      }
      return {
        ...view,
        entries: [
          ...view.entries,
          { kind: "message", message: { role: "assistant", content: "" } },
        ],
      };
    }

    case "messageDelta":
      return {
        ...view,
        entries: appendMessageDelta(view.entries, (event.delta as string) ?? ""),
      };

    case "thinkingStart":
      return {
        ...view,
        thinking: "",
        entries: [...view.entries, { kind: "thinking", text: "" }],
      };

    case "thinkingDelta": {
      const delta = (event.delta as string) ?? "";
      return {
        ...view,
        thinking: (view.thinking ?? "") + delta,
        entries: appendThinkingDelta(view.entries, delta),
      };
    }

    case "toolExecutionStart": {
      const e = event as unknown as ToolExecutionStartEvent;
      return {
        ...view,
        entries: [
          ...view.entries,
          {
            kind: "tool",
            tool: {
              tool: e.tool,
              callId: e.callId,
              args: e.args,
              meta: e.meta,
              status: "running",
              streamOutput: "",
            },
          },
        ],
      };
    }

    case "toolOutput": {
      const callId = (event as unknown as Record<string, string>).callId;
      const chunk = (event as unknown as Record<string, string>).chunk;
      return {
        ...view,
        entries: updateToolEntry(view.entries, callId, (t) => ({
          streamOutput: t.streamOutput + chunk,
        })),
      };
    }

    case "toolExecutionEnd": {
      const e = event as unknown as ToolExecutionEndEvent;
      return {
        ...view,
        entries: updateToolEntry(view.entries, e.callId, () => ({
          status: (e.result.ok ? "done" : "error") as ToolCall["status"],
          result: e.result as ToolCall["result"],
        })),
      };
    }

    case "statusUpdate":
      return { ...view, statusMessage: (event.message as string) ?? null };

    default:
      return view;
  }
}

// ── Agent map helpers ────────────────────────────────────────────

/** Update a single agent in the map, returning a new map. */
function updateAgent(
  agents: Readonly<Record<string, AgentView>>,
  id: string,
  patch: Partial<AgentView>,
): Record<string, AgentView> {
  const existing = agents[id];
  if (!existing) return agents as Record<string, AgentView>;
  return { ...agents, [id]: { ...existing, ...patch } };
}

/** Apply a view-level event to a specific agent in the map. */
function reduceAgentView(
  agents: Readonly<Record<string, AgentView>>,
  id: string,
  event: Record<string, unknown>,
): Record<string, AgentView> {
  const agent = agents[id];
  if (!agent) return agents as Record<string, AgentView>;
  const view = reduceView(agent, event);
  return { ...agents, [id]: { ...agent, ...view } };
}

// ── Top-level event reducer ──────────────────────────────────────

/** Apply a single agent event to the timeline state. Exported for testing. */
export function applyEvent(state: TimelineSnapshot, event: AgentEvent): TimelineSnapshot {
  switch (event.type) {
    // ── View events → root agent ──────────────────────────────
    case "agentStart":
    case "messageStart":
    case "messageDelta":
    case "thinkingStart":
    case "thinkingDelta":
    case "toolExecutionStart":
    case "toolExecutionEnd":
    case "toolOutput":
    case "statusUpdate":
      return {
        ...state,
        agents: reduceAgentView(
          state.agents,
          ROOT_AGENT_ID,
          event as unknown as Record<string, unknown>,
        ),
      };

    // ── Lifecycle events ──────────────────────────────────────
    case "agentAbort": {
      // Clear all sub-agents, reset focus, update root
      const root = state.agents[ROOT_AGENT_ID];
      return {
        ...state,
        agents: {
          [ROOT_AGENT_ID]: {
            ...root,
            isRunning: false,
            thinking: null,
            statusMessage: null,
          },
        },
        focusStack: [ROOT_AGENT_ID],
      };
    }

    case "agentEnd": {
      // Clear all sub-agents, reset focus, update root + token usage
      const root = state.agents[ROOT_AGENT_ID];
      return {
        ...state,
        agents: {
          [ROOT_AGENT_ID]: {
            ...root,
            isRunning: false,
            thinking: null,
            statusMessage: null,
          },
        },
        focusStack: [ROOT_AGENT_ID],
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
    }

    // ── Messages ──────────────────────────────────────────────
    case "messageApplied": {
      const idx = state.queuedMessages.indexOf(event.text);
      const nextQueued =
        idx >= 0
          ? [...state.queuedMessages.slice(0, idx), ...state.queuedMessages.slice(idx + 1)]
          : state.queuedMessages;
      const root = state.agents[ROOT_AGENT_ID];
      return {
        ...state,
        queuedMessages: nextQueued,
        agents: {
          ...state.agents,
          [ROOT_AGENT_ID]: {
            ...root,
            entries: [
              ...root.entries,
              { kind: "message", message: { role: "user", content: event.text } },
            ],
          },
        },
      };
    }

    case "messageQueued":
      return {
        ...state,
        queuedMessages: [...state.queuedMessages, event.text],
      };

    // ── Sub-agent events (normalized at boundary) ─────────────
    case "subAgentEvent": {
      const { inner, subSessionId, parentCallId } = event;
      const innerType = inner.type as string | undefined;

      // The inner event's `type` value arrives in snake_case from the wire
      // (snakeToCamel only transforms keys, not values). Convert it so
      // reduceView's camelCase switch statements match.
      const camelType = innerType?.replace(/_([a-z])/g, (_, c: string) => c.toUpperCase());

      // Birth: create a new agent in the map
      if (camelType === "subAgentStart") {
        const agent: AgentView = {
          id: subSessionId,
          parentCallId,
          label: (inner.label as string) ?? "",
          model: (inner.model as string) ?? "",
          tools: (inner.tools as string[]) ?? [],
          entries: [],
          thinking: null,
          statusMessage: null,
          isRunning: true,
          startedAt: Date.now(),
          toolCount: 0,
        };
        return {
          ...state,
          agents: { ...state.agents, [subSessionId]: agent },
        };
      }

      const existing = state.agents[subSessionId];
      if (!existing) return state;

      // Death: remove from map, auto-pop focus if viewing this agent
      if (camelType === "agentEnd") {
        const nextAgents = { ...state.agents };
        delete nextAgents[subSessionId];
        const focusedId = state.focusStack[state.focusStack.length - 1];
        const nextFocus =
          focusedId === subSessionId ? state.focusStack.slice(0, -1) : state.focusStack;
        return { ...state, agents: nextAgents, focusStack: nextFocus };
      }

      // Normal inner event → reduce the sub-agent's view
      const normalized = { ...inner, type: camelType };
      const view = reduceView(existing, normalized);
      const updated: AgentView = {
        ...existing,
        ...view,
        toolCount: camelType === "toolExecutionStart" ? existing.toolCount + 1 : existing.toolCount,
      };
      return {
        ...state,
        agents: { ...state.agents, [subSessionId]: updated },
      };
    }

    // ── Skills & context → root agent ─────────────────────────
    case "skillLoaded": {
      const root = state.agents[ROOT_AGENT_ID];
      return {
        ...state,
        agents: {
          ...state.agents,
          [ROOT_AGENT_ID]: {
            ...root,
            entries: [
              ...root.entries,
              { kind: "skill", skill: { name: event.name, description: event.description } },
            ],
          },
        },
      };
    }

    case "contextDiscovered": {
      const root = state.agents[ROOT_AGENT_ID];
      return {
        ...state,
        agents: {
          ...state.agents,
          [ROOT_AGENT_ID]: {
            ...root,
            entries: [...root.entries, { kind: "context", context: { files: event.files } }],
          },
        },
      };
    }

    // ── Recovery & errors ─────────────────────────────────────
    case "agentRecovered": {
      const root = state.agents[ROOT_AGENT_ID];
      return {
        ...state,
        timelineError: null,
        agents: updateAgent(state.agents, ROOT_AGENT_ID, {
          isRunning: false,
          entries: [
            ...root.entries,
            {
              kind: "message",
              message: {
                role: "assistant",
                content: "⚠ Agent crashed and recovered — conversation history preserved.",
              },
            },
          ],
        }),
      };
    }

    case "usageUpdate":
      return {
        ...state,
        tokenUsage: {
          promptTokens: event.usage.promptTokens,
          completionTokens: event.usage.completionTokens,
          totalTokens: event.usage.totalTokens,
          contextWindow: event.usage.contextWindow,
          currentContextTokens: event.usage.currentContextTokens,
        },
      };

    case "error":
      return {
        ...state,
        timelineError: event.reason,
        agents: updateAgent(state.agents, ROOT_AGENT_ID, { isRunning: false }),
      };

    default:
      return state;
  }
}

// ── Slice creator ────────────────────────────────────────────────

export const createTimelineSlice: StateCreator<TimelineSlice, [], [], TimelineSlice> = (set) => ({
  ...TIMELINE_INITIAL,

  applyEvents: (events) =>
    set((state) => {
      let snapshot: TimelineSnapshot = {
        agents: state.agents,
        focusStack: state.focusStack,
        tokenUsage: state.tokenUsage,
        queuedMessages: state.queuedMessages,
        timelineError: state.timelineError,
      };
      for (const event of events) {
        snapshot = applyEvent(snapshot, event);
      }
      return snapshot;
    }),

  focusAgent: (id) =>
    set((state) => {
      if (!state.agents[id]) return state;
      return { focusStack: [...state.focusStack, id] };
    }),

  focusBack: () =>
    set((state) => {
      if (state.focusStack.length <= 1) return state;
      return { focusStack: state.focusStack.slice(0, -1) };
    }),

  resetTimeline: () => set(TIMELINE_INITIAL),

  pushStatus: (text, level = "info") =>
    set((state) => {
      const focusedId = state.focusStack[state.focusStack.length - 1] ?? ROOT_AGENT_ID;
      const agent = state.agents[focusedId];
      if (!agent) return state;
      return {
        agents: {
          ...state.agents,
          [focusedId]: {
            ...agent,
            entries: [...agent.entries, { kind: "status", text, level }],
          },
        },
      };
    }),
});
