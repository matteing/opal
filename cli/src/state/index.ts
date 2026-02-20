/**
 * Opal state management — public API.
 *
 * @example
 * ```tsx
 * import { useOpalStore, useActiveAgent } from "../state/index.js";
 *
 * const { entries, isRunning, thinking } = useActiveAgent();
 * const connect = useOpalStore((s) => s.connect);
 * ```
 *
 * @module
 */

// Store
export { useOpalStore } from "./store.js";
export type { OpalStore } from "./store.js";

// Selectors
export { useActiveAgent, selectFocusedAgent } from "./selectors.js";

// Types
export type {
  Message,
  ToolCall,
  Skill,
  ContextInfo,
  TimelineEntry,
  AgentView,
  ModelInfo,
  ActiveModel,
  AuthStatus,
  RpcLogEntry,
  StderrEntry,
  SessionStatus,
  TokenUsage,
} from "./types.js";

// Slice types (for advanced composition / testing)
export type { TimelineSlice } from "./timeline.js";
export type { ModelsSlice } from "./models.js";
export type { AuthSlice } from "./auth.js";
export type { DebugSlice } from "./debug.js";
export type { SessionSlice } from "./session.js";
export type { CliStateSlice } from "./cli.js";

// Constants
export { ROOT_AGENT_ID } from "./timeline.js";

// Pure reducer (for testing without React/Zustand)
export { applyEvent } from "./timeline.js";
export type { TimelineSnapshot } from "./timeline.js";
