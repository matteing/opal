/**
 * Derived selectors for agent-focused state.
 *
 * Components use {@link useActiveAgent} to read from whichever agent
 * is currently focused — root or sub-agent. They never need to know
 * which agent they're rendering.
 *
 * @module
 */

import { useOpalStore } from "./store.js";
import { ROOT_AGENT_ID } from "./timeline.js";
import type { AgentView } from "./types.js";
import type { OpalStore } from "./store.js";

// ── Selector functions ───────────────────────────────────────────

/** Select the currently focused agent from the store. */
export function selectFocusedAgent(s: OpalStore): AgentView {
  const focusedId = s.focusStack[s.focusStack.length - 1] ?? ROOT_AGENT_ID;
  return s.agents[focusedId] ?? s.agents[ROOT_AGENT_ID];
}

// ── React hooks ──────────────────────────────────────────────────

/**
 * Read the focused agent's view state. Automatically updates when
 * the focus changes or the focused agent receives new events.
 *
 * @example
 * ```tsx
 * const { entries, isRunning, thinking } = useActiveAgent();
 * ```
 */
export function useActiveAgent(): AgentView {
  return useOpalStore(selectFocusedAgent);
}
