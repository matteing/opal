/**
 * Pure event reducer: maps a single AgentEvent into a SessionView update.
 *
 * This function is intentionally pure — it takes a view and an event, and
 * returns a new view. No side effects, no store access, no bridge calls.
 * This makes it trivially testable and easy to reason about.
 *
 * The store calls this function inside `set()` to apply events to the
 * correct session's view. Events from background sessions update their
 * own view without affecting the active session's UI.
 */

import type { AgentEventWire } from "../sdk/bridge.js";
import type { SessionView, TimelineEntry } from "./types.js";

export function applyEventToView(
  view: SessionView,
  event: AgentEventWire,
): SessionView {
  switch (event.type) {
    // ── Agent lifecycle ────────────────────────────────────
    case "agentStart":
      return { ...view, isRunning: true, statusMessage: "", thinkingText: "" };

    case "agentEnd": {
      // Finalize any streaming assistant message
      const tl = view.timeline.map((e) =>
        e.type === "assistant" && e.isStreaming ? { ...e, isStreaming: false } : e,
      );
      return {
        ...view,
        timeline: tl,
        isRunning: false,
        thinkingText: "",
        statusMessage: "",
      };
    }

    case "agentAbort": {
      const tl = view.timeline.map((e) =>
        e.type === "assistant" && e.isStreaming ? { ...e, isStreaming: false } : e,
      );
      return {
        ...view,
        timeline: [...tl, { type: "status", message: "Cancelled" }],
        isRunning: false,
        thinkingText: "",
        statusMessage: "",
      };
    }

    // ── Message streaming ──────────────────────────────────
    case "messageStart":
      return {
        ...view,
        timeline: [
          ...view.timeline,
          { type: "assistant", text: "", isStreaming: true },
        ],
      };

    case "messageDelta": {
      const delta = (event.delta as string) ?? "";
      const tl = [...view.timeline];
      const last = tl[tl.length - 1];
      if (last?.type === "assistant") {
        tl[tl.length - 1] = { ...last, text: last.text + delta };
      }
      return { ...view, timeline: tl };
    }

    // ── Thinking / status ──────────────────────────────────
    case "thinkingStart":
      return { ...view, thinkingText: "" };

    case "thinkingDelta":
      return {
        ...view,
        thinkingText: view.thinkingText + ((event.delta as string) ?? ""),
      };

    case "statusUpdate":
      return { ...view, statusMessage: (event.message as string) ?? "" };

    // ── Tool execution ─────────────────────────────────────
    case "toolExecutionStart": {
      const entry: TimelineEntry = {
        type: "tool",
        name: (event.tool as string) ?? "unknown",
        callId: (event.callId as string) ?? "",
        args:
          typeof event.args === "string"
            ? event.args
            : JSON.stringify(event.args ?? {}),
        output: null,
        status: "running",
      };
      return { ...view, timeline: [...view.timeline, entry] };
    }

    case "toolExecutionEnd": {
      // Match by callId and fill in the result
      const callId = (event.callId as string) ?? "";
      const tl = view.timeline.map((e) => {
        if (e.type === "tool" && e.callId === callId) {
          return {
            ...e,
            output:
              typeof event.result === "string"
                ? event.result
                : JSON.stringify(event.result ?? ""),
            status: "done" as const,
          };
        }
        return e;
      });
      return { ...view, timeline: tl };
    }

    // ── Usage / model info ─────────────────────────────────
    case "usageUpdate": {
      const usage = event.usage as Record<string, number> | undefined;
      return {
        ...view,
        currentModel: (event.model as string) ?? view.currentModel,
        tokenUsage: usage
          ? {
              current: usage.currentContextTokens ?? usage.totalTokens ?? 0,
              contextWindow: usage.contextWindow ?? 128_000,
            }
          : view.tokenUsage,
      };
    }

    // ── Context discovery ──────────────────────────────────
    case "contextDiscovered": {
      const files = (event.files as string[]) ?? [];
      const entries: TimelineEntry[] = files.map((f) => ({
        type: "context" as const,
        label: f,
      }));
      return { ...view, timeline: [...view.timeline, ...entries] };
    }

    case "skillLoaded":
      return {
        ...view,
        timeline: [
          ...view.timeline,
          { type: "skill", name: (event.name as string) ?? "unknown" },
        ],
      };

    // ── Errors go to root state, not per-view ──────────────
    case "error":
      return view;

    default:
      return view;
  }
}
