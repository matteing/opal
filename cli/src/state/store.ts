/**
 * Opal store — centralized state via Zustand with sliced concerns.
 *
 * Composes five independent slices into a single store:
 *
 * | Slice     | Concern                              |
 * |-----------|--------------------------------------|
 * | session   | Connection lifecycle, event wiring    |
 * | timeline  | Agent events → normalized agent views |
 * | models    | Model listing and selection           |
 * | auth      | Authentication flow state machine     |
 * | debug     | RPC message log, stderr capture       |
 *
 * All agents (root + sub-agents) live in a single `agents` map.
 * A focus stack tracks which agent the UI is viewing. Components
 * use `useActiveAgent()` to read from the focused agent.
 *
 * @example
 * ```tsx
 * import { useOpalStore } from "../state/store.js";
 * import { useActiveAgent } from "../state/selectors.js";
 *
 * // Read the focused agent's view — works for root or sub-agents
 * function MessageList() {
 *   const { entries, isRunning } = useActiveAgent();
 *   return <Timeline entries={entries} loading={isRunning} />;
 * }
 *
 * function StatusBar() {
 *   const model = useOpalStore((s) => s.currentModel);
 *   const usage = useOpalStore((s) => s.tokenUsage);
 *   return <Bar model={model?.displayName} tokens={usage?.totalTokens} />;
 * }
 *
 * // Navigate into a sub-agent
 * function SubAgentTab({ id }: { id: string }) {
 *   const focusAgent = useOpalStore((s) => s.focusAgent);
 *   return <Button onPress={() => focusAgent(id)}>View</Button>;
 * }
 * ```
 *
 * @module
 */

import { create } from "zustand";
import { createTimelineSlice, type TimelineSlice } from "./timeline.js";
import { createModelsSlice, type ModelsSlice } from "./models.js";
import { createAuthSlice, type AuthSlice } from "./auth.js";
import { createDebugSlice, type DebugSlice } from "./debug.js";
import { createSessionSlice, type SessionSlice } from "./session.js";
import { createCliStateSlice, type CliStateSlice } from "./cli.js";

// ── Combined store type ──────────────────────────────────────────

export interface OpalStore
  extends SessionSlice, TimelineSlice, ModelsSlice, AuthSlice, DebugSlice, CliStateSlice {}

// ── Store creation ───────────────────────────────────────────────

/**
 * The Opal store.
 *
 * Use `useOpalStore(selector)` for React components:
 * ```ts
 * const { entries, isRunning } = useActiveAgent();
 * ```
 *
 * Use `useOpalStore.getState()` for imperative access outside React:
 * ```ts
 * useOpalStore.getState().connect({ workingDir: "." });
 * ```
 */
export const useOpalStore = create<OpalStore>()((...a) => ({
  ...createSessionSlice(...a),
  ...createTimelineSlice(...a),
  ...createModelsSlice(...a),
  ...createAuthSlice(...a),
  ...createDebugSlice(...a),
  ...createCliStateSlice(...a),
}));
