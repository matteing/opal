/**
 * Selector hooks for Opal Desktop state.
 *
 * Components should import from here instead of using useAppStore() directly.
 * Each hook selects only the data its component needs, preventing unnecessary
 * re-renders when unrelated state changes.
 *
 * Convention:
 *   - Primitive selectors (string, number, boolean, null) are stable by default.
 *   - Object/array selectors use useShallow to prevent reference-inequality re-renders.
 *   - Actions are grouped into logical bundles (e.g. useSessionActions).
 *
 * @example
 * // ✅ Good — only re-renders when timeline changes
 * const { timeline, isRunning } = useCurrentView();
 *
 * // ❌ Bad — re-renders on ANY state change
 * const { timeline, isRunning } = useAppStore();
 */

import { useShallow } from "zustand/react/shallow";
import { useAppStore, type AppState } from "./store.js";
import type { SessionListEntry, SessionView } from "./types.js";

// ── Current session view ─────────────────────────────────────

/**
 * The active session's view state (timeline, isRunning, thinking, etc.).
 * Returns null if no session is active.
 */
export function useCurrentView(): SessionView | null {
  return useAppStore((s) => {
    if (!s.activeSessionId) return null;
    return s.sessionViews[s.activeSessionId] ?? null;
  });
}

/** Whether the active session's agent is currently running. */
export function useIsRunning(): boolean {
  return useAppStore((s) => {
    if (!s.activeSessionId) return false;
    return s.sessionViews[s.activeSessionId]?.isRunning ?? false;
  });
}

// ── Session list ─────────────────────────────────────────────

/** The list of all sessions (saved + active). */
export function useSessions(): SessionListEntry[] {
  return useAppStore(useShallow((s) => s.sessions));
}

/** The currently active session ID (null if none). */
export function useActiveSessionId(): string | null {
  return useAppStore((s) => s.activeSessionId);
}

// ── Header data ──────────────────────────────────────────────

/** Data for the AppHeader component. */
export function useHeaderData() {
  return useAppStore(
    useShallow((s) => ({
      workingDir: s.workingDir,
      model: s.activeSessionId
        ? s.sessionViews[s.activeSessionId]?.currentModel ?? null
        : null,
      tokenUsage: s.activeSessionId
        ? s.sessionViews[s.activeSessionId]?.tokenUsage ?? null
        : null,
    })),
  );
}

// ── Global state ─────────────────────────────────────────────

/** Current error message (null if no error). */
export function useError(): string | null {
  return useAppStore((s) => s.error);
}

/** Currently open overlay panel (null if none). */
export function useOverlay(): AppState["overlay"] {
  return useAppStore((s) => s.overlay);
}

// ── Actions ──────────────────────────────────────────────────
// Grouped by concern. Actions are stable references (functions don't change).

/** Actions for managing the session lifecycle (create, resume, switch, delete). */
export function useSessionActions() {
  return useAppStore(
    useShallow((s) => ({
      createSession: s.createSession,
      resumeSession: s.resumeSession,
      switchSession: s.switchSession,
      deleteSession: s.deleteSession,
      refreshSessionList: s.refreshSessionList,
    })),
  );
}

/** Actions for the active conversation (prompt, steer, abort). */
export function useConversationActions() {
  return useAppStore(
    useShallow((s) => ({
      submitPrompt: s.submitPrompt,
      submitSteer: s.submitSteer,
      abort: s.abort,
    })),
  );
}

/** Actions for resolving pending dialogs. */
export function useDialogActions() {
  return useAppStore(
    useShallow((s) => ({
      resolveConfirmation: s.resolveConfirmation,
      resolveAskUser: s.resolveAskUser,
    })),
  );
}
