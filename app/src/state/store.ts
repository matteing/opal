import { create } from "zustand";
import {
  bridge,
  type AgentEventWire,
  type SessionListItem,
  type HistoryMessage,
} from "../sdk/bridge.js";
import type {
  TimelineEntry,
  TokenUsage,
  ConfirmRequest,
  AskUserRequest,
} from "./types.js";

// ── Per-session view state ───────────────────────────────────

export interface SessionView {
  timeline: TimelineEntry[];
  isRunning: boolean;
  thinkingText: string;
  statusMessage: string;
  tokenUsage: TokenUsage | null;
  currentModel: string | null;
  confirmation: ConfirmRequest | null;
  askUser: AskUserRequest | null;
}

function emptyView(): SessionView {
  return {
    timeline: [],
    isRunning: false,
    thinkingText: "",
    statusMessage: "",
    tokenUsage: null,
    currentModel: null,
    confirmation: null,
    askUser: null,
  };
}

// ── Session list entry ───────────────────────────────────────

export interface SessionListEntry {
  id: string;
  title: string;
  workingDir: string;
  createdAt: string;
  active: boolean; // loaded in memory
}

// ── Root state ───────────────────────────────────────────────

export interface AppState {
  // Session management
  sessions: SessionListEntry[];
  activeSessionId: string | null;
  sessionViews: Record<string, SessionView>;

  // Derived convenience (null if no active session)
  currentView: SessionView | null;
  workingDir: string;
  error: string | null;

  // Actions — session lifecycle
  createSession: (workingDir?: string) => Promise<void>;
  resumeSession: (id: string, workingDir?: string) => Promise<void>;
  switchSession: (id: string) => void;
  deleteSession: (id: string) => Promise<void>;
  refreshSessionList: () => Promise<void>;

  // Actions — active session
  applyEvent: (event: AgentEventWire) => void;
  submitPrompt: (text: string) => void;
  submitSteer: (text: string) => void;
  abort: () => void;
  resolveConfirmation: (action: string) => void;
  resolveAskUser: (answer: string) => void;
  branchSession: (messageId: string) => Promise<void>;

  // Actions — general
  setError: (error: string | null) => void;
}

// ── Auto-title from first prompt ─────────────────────────────

function autoTitle(text: string): string {
  const firstLine = text.split("\n")[0] ?? text;
  return firstLine.length > 50 ? firstLine.slice(0, 47) + "…" : firstLine;
}

// ── History → timeline conversion ────────────────────────────

function historyToTimeline(messages: HistoryMessage[]): TimelineEntry[] {
  const entries: TimelineEntry[] = [];

  for (const msg of messages) {
    switch (msg.role) {
      case "user":
        if (msg.content) entries.push({ type: "user", text: msg.content });
        break;
      case "assistant":
        if (msg.content) {
          entries.push({ type: "assistant", text: msg.content, isStreaming: false });
        }
        if (msg.toolCalls) {
          for (const tc of msg.toolCalls) {
            entries.push({
              type: "tool",
              name: tc.name,
              callId: tc.callId,
              args: tc.arguments,
              output: null,
              status: "done",
            });
          }
        }
        break;
      case "tool_result":
        // Match to existing tool entry and fill in output
        if (msg.callId) {
          for (let i = entries.length - 1; i >= 0; i--) {
            const e = entries[i];
            if (e.type === "tool" && e.callId === msg.callId) {
              entries[i] = { ...e, output: msg.content ?? null };
              break;
            }
          }
        }
        break;
    }
  }
  return entries;
}

// ── Store ────────────────────────────────────────────────────

export const useAppStore = create<AppState>((set, get) => ({
  sessions: [],
  activeSessionId: null,
  sessionViews: {},
  currentView: null,
  workingDir: "",
  error: null,

  // ── Session lifecycle ──────────────────────────────────────

  createSession: async (workingDir?: string) => {
    try {
      let dir = workingDir;
      if (!dir) {
        dir = await bridge.openDirectoryPicker() ?? undefined;
        if (!dir) return; // user cancelled
      }
      const entry = await bridge.createSession({ workingDir: dir });
      const view = emptyView();

      set((s) => {
        const sessionEntry: SessionListEntry = {
          id: entry.id,
          title: "New conversation",
          workingDir: entry.workingDir,
          createdAt: new Date().toISOString(),
          active: true,
        };
        const sessions = [...s.sessions, sessionEntry];
        const sessionViews = { ...s.sessionViews, [entry.id]: view };
        return {
          sessions,
          activeSessionId: entry.id,
          sessionViews,
          currentView: view,
          workingDir: entry.workingDir,
          error: null,
        };
      });
    } catch (e) {
      set({ error: `Failed to create session: ${e}` });
    }
  },

  resumeSession: async (id: string, workingDir?: string) => {
    try {
      // If already loaded, just switch
      const existing = get().sessionViews[id];
      if (existing) {
        get().switchSession(id);
        return;
      }

      const entry = await bridge.resumeSession(id, { workingDir });
      const historyResult = await bridge.getHistory(id);
      const timeline = historyToTimeline(historyResult.messages ?? []);
      const view: SessionView = { ...emptyView(), timeline };

      set((s) => {
        const sessions = s.sessions.map((se) =>
          se.id === id ? { ...se, active: true } : se,
        );
        const sessionViews = { ...s.sessionViews, [id]: view };
        return {
          sessions,
          activeSessionId: id,
          sessionViews,
          currentView: view,
          workingDir: entry.workingDir || workingDir || "",
          error: null,
        };
      });
    } catch (e) {
      set({ error: `Failed to resume session: ${e}` });
    }
  },

  switchSession: (id: string) => {
    const view = get().sessionViews[id];
    if (!view) return;

    bridge.switchSession(id);

    const session = get().sessions.find((s) => s.id === id);
    set({
      activeSessionId: id,
      currentView: view,
      workingDir: session?.workingDir ?? "",
    });
  },

  deleteSession: async (id: string) => {
    try {
      await bridge.deleteSession(id);
      set((s) => {
        const sessions = s.sessions.filter((se) => se.id !== id);
        const { [id]: _, ...sessionViews } = s.sessionViews;

        let activeSessionId = s.activeSessionId;
        let currentView = s.currentView;
        let workingDir = s.workingDir;

        if (activeSessionId === id) {
          // Switch to next available or clear
          const nextActive = sessions.find((se) => se.active);
          activeSessionId = nextActive?.id ?? null;
          currentView = activeSessionId ? sessionViews[activeSessionId] ?? null : null;
          workingDir = nextActive?.workingDir ?? "";
        }

        return { sessions, sessionViews, activeSessionId, currentView, workingDir };
      });
    } catch (e) {
      set({ error: `Failed to delete session: ${e}` });
    }
  },

  refreshSessionList: async () => {
    try {
      const result = await bridge.listSessions();
      const items: SessionListItem[] = result.sessions ?? [];
      set((s) => {
        const sessions: SessionListEntry[] = items.map((item) => {
          const existing = s.sessions.find((se) => se.id === item.id);
          return {
            id: item.id,
            title: (item.title as string) ?? existing?.title ?? "Untitled",
            workingDir: existing?.workingDir ?? "",
            createdAt: (item.modified as string) ?? existing?.createdAt ?? "",
            active: !!s.sessionViews[item.id],
          };
        });
        return { sessions };
      });
    } catch {
      // Silently fail — list is best-effort
    }
  },

  // ── Active session actions ─────────────────────────────────

  applyEvent: (event: AgentEventWire) => {
    const sessionId = event.sessionId ?? get().activeSessionId;
    if (!sessionId) return;

    set((s) => {
      const view = s.sessionViews[sessionId] ?? emptyView();
      const updated = applyEventToView(view, event);
      const sessionViews = { ...s.sessionViews, [sessionId]: updated };

      // Update session title from first user message
      if (event.type === "agentEnd") {
        const firstUser = updated.timeline.find((e) => e.type === "user");
        if (firstUser && firstUser.type === "user") {
          const sessions = s.sessions.map((se) =>
            se.id === sessionId && se.title === "New conversation"
              ? { ...se, title: autoTitle(firstUser.text) }
              : se,
          );
          return {
            sessionViews,
            sessions,
            currentView: sessionId === s.activeSessionId ? updated : s.currentView,
          };
        }
      }

      return {
        sessionViews,
        currentView: sessionId === s.activeSessionId ? updated : s.currentView,
      };
    });
  },

  submitPrompt: (text: string) => {
    const { activeSessionId, sessionViews } = get();
    if (!activeSessionId) return;

    const view = sessionViews[activeSessionId];
    if (!view) return;

    const updated = {
      ...view,
      timeline: [...view.timeline, { type: "user" as const, text }],
    };

    set((s) => ({
      sessionViews: { ...s.sessionViews, [activeSessionId]: updated },
      currentView: updated,
      error: null,
    }));

    bridge.prompt(text).catch((e) => {
      set({ error: `Prompt failed: ${e}` });
    });
  },

  submitSteer: (text: string) => {
    bridge.steer(text).catch((e) => {
      set({ error: `Steer failed: ${e}` });
    });
  },

  abort: () => {
    bridge.abort().catch(() => {});
  },

  resolveConfirmation: (action: string) => {
    const { activeSessionId, sessionViews } = get();
    if (!activeSessionId) return;
    const view = sessionViews[activeSessionId];
    if (!view?.confirmation) return;

    bridge.resolveConfirm(view.confirmation.id, action);
    const updated = { ...view, confirmation: null };
    set((s) => ({
      sessionViews: { ...s.sessionViews, [activeSessionId]: updated },
      currentView: updated,
    }));
  },

  resolveAskUser: (answer: string) => {
    const { activeSessionId, sessionViews } = get();
    if (!activeSessionId) return;
    const view = sessionViews[activeSessionId];
    if (!view?.askUser) return;

    bridge.resolveAskUser(view.askUser.id, answer);
    const updated = { ...view, askUser: null };
    set((s) => ({
      sessionViews: { ...s.sessionViews, [activeSessionId]: updated },
      currentView: updated,
    }));
  },

  branchSession: async (messageId: string) => {
    const { activeSessionId } = get();
    if (!activeSessionId) return;
    try {
      await bridge.branchSession(activeSessionId, messageId);
      // Reload history to get the branched state
      const historyResult = await bridge.getHistory(activeSessionId);
      const timeline = historyToTimeline(historyResult.messages ?? []);
      set((s) => {
        const view = { ...(s.sessionViews[activeSessionId] ?? emptyView()), timeline };
        return {
          sessionViews: { ...s.sessionViews, [activeSessionId]: view },
          currentView: view,
        };
      });
    } catch (e) {
      set({ error: `Branch failed: ${e}` });
    }
  },

  setError: (error: string | null) => set({ error }),
}));

// ── Event reducer (operates on a single SessionView) ─────────

function applyEventToView(view: SessionView, event: AgentEventWire): SessionView {
  const { type } = event;

  switch (type) {
    case "agentStart":
      return { ...view, isRunning: true, statusMessage: "", thinkingText: "" };

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

    case "thinkingStart":
      return { ...view, thinkingText: "" };

    case "thinkingDelta": {
      const delta = (event.delta as string) ?? "";
      return { ...view, thinkingText: view.thinkingText + delta };
    }

    case "statusUpdate":
      return { ...view, statusMessage: (event.message as string) ?? "" };

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

    case "usageUpdate": {
      const usage = event.usage as Record<string, number> | undefined;
      return {
        ...view,
        currentModel: (event.model as string) ?? view.currentModel,
        tokenUsage: usage
          ? {
              current: usage.currentContextTokens ?? usage.totalTokens ?? 0,
              contextWindow: usage.contextWindow ?? 128000,
            }
          : view.tokenUsage,
      };
    }

    case "agentEnd": {
      const tl = view.timeline.map((e) =>
        e.type === "assistant" && e.isStreaming ? { ...e, isStreaming: false } : e,
      );
      return { ...view, timeline: tl, isRunning: false, thinkingText: "", statusMessage: "" };
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

    case "error":
      return view; // errors go to root state, not per-view

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

    default:
      return view;
  }
}
