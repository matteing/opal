/**
 * Opal Desktop — Zustand store.
 *
 * Architecture:
 *
 *   AppState
 *   ├── sessions: SessionListEntry[]        — sidebar list (saved + active)
 *   ├── activeSessionId: string | null      — which session is focused
 *   ├── sessionViews: { [id]: SessionView } — per-session conversation state
 *   ├── workingDir: string                  — active session's working directory
 *   ├── error: string | null                — global error banner
 *   └── actions                             — session lifecycle + conversation
 *
 * Key design decisions:
 *
 *   1. `sessionViews` is the source of truth for conversation state.
 *      There is no duplicated `currentView` field — components derive it
 *      via `useCurrentView()` (see selectors.ts).
 *
 *   2. Events arrive tagged with `sessionId` from the main process.
 *      `applyEvent` routes each event to the correct session's view,
 *      so background sessions update independently.
 *
 *   3. The event reducer (`applyEventToView`) is a pure function in its
 *      own file for testability. The store just calls it and merges the
 *      result.
 *
 *   4. Components use selector hooks (selectors.ts) instead of destructuring
 *      the full store — this prevents re-renders when unrelated state changes.
 */

import { create } from "zustand";
import { bridge, type AgentEventWire, type SessionListItem } from "../sdk/bridge.js";
import type { SessionListEntry, SessionView } from "./types.js";
import { applyEventToView } from "./event-reducer.js";
import { historyToTimeline, autoTitle } from "./history.js";

// ── Helpers ──────────────────────────────────────────────────

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

// ── State shape ──────────────────────────────────────────────

export interface AppState {
  // Data
  sessions: SessionListEntry[];
  activeSessionId: string | null;
  sessionViews: Record<string, SessionView>;
  workingDir: string;
  error: string | null;

  // Session lifecycle
  createSession: (workingDir?: string) => Promise<void>;
  resumeSession: (id: string, workingDir?: string) => Promise<void>;
  switchSession: (id: string) => void;
  deleteSession: (id: string) => Promise<void>;
  refreshSessionList: () => Promise<void>;

  // Active session conversation
  applyEvent: (event: AgentEventWire) => void;
  submitPrompt: (text: string) => void;
  submitSteer: (text: string) => void;
  abort: () => void;
  resolveConfirmation: (action: string) => void;
  resolveAskUser: (answer: string) => void;
  branchSession: (messageId: string) => Promise<void>;

  // General
  setError: (error: string | null) => void;
}

// ── Store ────────────────────────────────────────────────────

export const useAppStore = create<AppState>((set, get) => ({
  sessions: [],
  activeSessionId: null,
  sessionViews: {},
  workingDir: "",
  error: null,

  // ── Session lifecycle ────────────────────────────────────

  createSession: async (workingDir?: string) => {
    try {
      // If no dir provided, prompt user with native OS directory picker
      let dir = workingDir;
      if (!dir) {
        dir = (await bridge.openDirectoryPicker()) ?? undefined;
        if (!dir) return; // user cancelled picker
      }

      const entry = await bridge.createSession({ workingDir: dir });
      const view = emptyView();
      const sessionEntry: SessionListEntry = {
        id: entry.id,
        title: "New conversation",
        workingDir: entry.workingDir,
        createdAt: new Date().toISOString(),
        active: true,
      };

      set((s) => ({
        sessions: [...s.sessions, sessionEntry],
        activeSessionId: entry.id,
        sessionViews: { ...s.sessionViews, [entry.id]: view },
        workingDir: entry.workingDir,
        error: null,
      }));
    } catch (e) {
      set({ error: `Failed to create session: ${e}` });
    }
  },

  resumeSession: async (id: string, workingDir?: string) => {
    try {
      // Already loaded? Just switch focus.
      if (get().sessionViews[id]) {
        get().switchSession(id);
        return;
      }

      // Load from disk via SDK, then fetch history for timeline replay
      const entry = await bridge.resumeSession(id, { workingDir });
      const historyResult = await bridge.getHistory(id);
      const timeline = historyToTimeline(historyResult.messages ?? []);
      const view: SessionView = { ...emptyView(), timeline };
      const resolvedDir = entry.workingDir || workingDir || "";

      set((s) => ({
        sessions: s.sessions.map((se) =>
          se.id === id ? { ...se, active: true } : se,
        ),
        activeSessionId: id,
        sessionViews: { ...s.sessionViews, [id]: view },
        workingDir: resolvedDir,
        error: null,
      }));
    } catch (e) {
      set({ error: `Failed to resume session: ${e}` });
    }
  },

  switchSession: (id: string) => {
    if (!get().sessionViews[id]) return;
    bridge.switchSession(id);
    const session = get().sessions.find((s) => s.id === id);
    set({ activeSessionId: id, workingDir: session?.workingDir ?? "" });
  },

  deleteSession: async (id: string) => {
    try {
      await bridge.deleteSession(id);

      set((s) => {
        const sessions = s.sessions.filter((se) => se.id !== id);
        const { [id]: _, ...sessionViews } = s.sessionViews;

        // If we deleted the active session, switch to next available
        if (s.activeSessionId === id) {
          const next = sessions.find((se) => se.active);
          return {
            sessions,
            sessionViews,
            activeSessionId: next?.id ?? null,
            workingDir: next?.workingDir ?? "",
          };
        }

        return { sessions, sessionViews };
      });
    } catch (e) {
      set({ error: `Failed to delete session: ${e}` });
    }
  },

  refreshSessionList: async () => {
    try {
      const result = await bridge.listSessions();
      const items: SessionListItem[] = result.sessions ?? [];

      set((s) => ({
        sessions: items.map((item) => {
          // Preserve local state (workingDir, active) for sessions we already know
          const existing = s.sessions.find((se) => se.id === item.id);
          return {
            id: item.id,
            title: (item.title as string) ?? existing?.title ?? "Untitled",
            workingDir: existing?.workingDir ?? "",
            createdAt: (item.modified as string) ?? existing?.createdAt ?? "",
            active: !!s.sessionViews[item.id],
          };
        }),
      }));
    } catch {
      // Session list is best-effort — don't show errors for this
    }
  },

  // ── Event handling ───────────────────────────────────────

  applyEvent: (event: AgentEventWire) => {
    // Events arrive tagged with sessionId from the main process.
    // Route to the correct session view (may differ from the active one
    // if a background session is still running).
    const sessionId = event.sessionId ?? get().activeSessionId;
    if (!sessionId) return;

    // Global errors go to root state, not per-session
    if (event.type === "error") {
      set({ error: (event.reason as string) ?? "An error occurred" });
      return;
    }

    set((s) => {
      const view = s.sessionViews[sessionId] ?? emptyView();
      const updated = applyEventToView(view, event);
      const sessionViews = { ...s.sessionViews, [sessionId]: updated };

      // Auto-title: when the agent finishes its first turn, derive the
      // session title from the first user message
      let { sessions } = s;
      if (event.type === "agentEnd") {
        const firstUser = updated.timeline.find((e) => e.type === "user");
        if (firstUser?.type === "user") {
          sessions = sessions.map((se) =>
            se.id === sessionId && se.title === "New conversation"
              ? { ...se, title: autoTitle(firstUser.text) }
              : se,
          );
        }
      }

      return { sessionViews, sessions };
    });
  },

  // ── Active session conversation ──────────────────────────

  submitPrompt: (text: string) => {
    const { activeSessionId } = get();
    if (!activeSessionId) return;

    // Optimistically add user message to timeline before sending
    set((s) => {
      const view = s.sessionViews[activeSessionId];
      if (!view) return s;
      const updated = {
        ...view,
        timeline: [...view.timeline, { type: "user" as const, text }],
      };
      return {
        sessionViews: { ...s.sessionViews, [activeSessionId]: updated },
        error: null,
      };
    });

    bridge.prompt(text).catch((e) => set({ error: `Prompt failed: ${e}` }));
  },

  submitSteer: (text: string) => {
    bridge.steer(text).catch((e) => set({ error: `Steer failed: ${e}` }));
  },

  abort: () => {
    bridge.abort().catch(() => {});
  },

  resolveConfirmation: (action: string) => {
    const { activeSessionId } = get();
    if (!activeSessionId) return;

    set((s) => {
      const view = s.sessionViews[activeSessionId];
      if (!view?.confirmation) return s;
      bridge.resolveConfirm(view.confirmation.id, action);
      return {
        sessionViews: {
          ...s.sessionViews,
          [activeSessionId]: { ...view, confirmation: null },
        },
      };
    });
  },

  resolveAskUser: (answer: string) => {
    const { activeSessionId } = get();
    if (!activeSessionId) return;

    set((s) => {
      const view = s.sessionViews[activeSessionId];
      if (!view?.askUser) return s;
      bridge.resolveAskUser(view.askUser.id, answer);
      return {
        sessionViews: {
          ...s.sessionViews,
          [activeSessionId]: { ...view, askUser: null },
        },
      };
    });
  },

  branchSession: async (messageId: string) => {
    const { activeSessionId } = get();
    if (!activeSessionId) return;
    try {
      await bridge.branchSession(activeSessionId, messageId);
      // Reload history to get the new branch's timeline
      const historyResult = await bridge.getHistory(activeSessionId);
      const timeline = historyToTimeline(historyResult.messages ?? []);
      set((s) => {
        const view = { ...(s.sessionViews[activeSessionId] ?? emptyView()), timeline };
        return {
          sessionViews: { ...s.sessionViews, [activeSessionId]: view },
        };
      });
    } catch (e) {
      set({ error: `Branch failed: ${e}` });
    }
  },

  setError: (error: string | null) => set({ error }),
}));
