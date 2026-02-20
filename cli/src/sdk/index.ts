/**
 * Opal SDK — TypeScript client for the Opal agent runtime.
 *
 * @example Quick start
 * ```ts
 * import { createSession } from "./sdk2/index.js";
 *
 * const session = await createSession({ workingDir: "." });
 *
 * for await (const event of session.prompt("Hello!")) {
 *   if (event.type === "messageDelta") process.stdout.write(event.delta);
 * }
 *
 * session.close();
 * ```
 *
 * @module
 */

// ── Primary API ─────────────────────────────────────────────────────
// The main entry point — most consumers only need this.
export { createSession, Session, type SessionOptions } from "./session.js";

// ── Stream ──────────────────────────────────────────────────────────
export { AgentStream, type FinalMessage } from "./stream.js";

// ── Event Matching ──────────────────────────────────────────────────
export {
  matchEvent,
  matchEventPartial,
  isEventType,
  assertNever,
  type AgentEventType,
  type EventOfType,
  type AgentEventVisitor,
  type PartialVisitor,
} from "./match.js";

// ── Errors ──────────────────────────────────────────────────────────
export {
  OpalError,
  ConnectionError,
  TimeoutError,
  RpcError,
  AbortError,
  ClientClosedError,
  isOpalError,
  isErrorCode,
  type OpalErrorCode,
} from "./errors.js";

// ── Low-level (advanced usage) ──────────────────────────────────────
export { OpalClient, type ServerMethodHandler, type AgentEventHandler } from "./client.js";
export {
  RpcConnection,
  type RpcObserver,
  type MethodHandler,
  type NotificationHandler,
} from "./rpc/connection.js";
export { type Transport, type TransportState, type Disposable } from "./transport/transport.js";
export { StdioTransport, type StdioTransportOptions } from "./transport/stdio.js";
export { createMemoryTransport } from "./transport/memory.js";
export { resolveServer, type ServerResolution } from "./resolve.js";
export { snakeToCamel, camelToSnake } from "./transforms.js";

// ── Protocol types (auto-generated) ─────────────────────────────────
// Re-export the method constants and all type definitions consumers need.
export { Methods } from "../sdk/protocol.js";

export type {
  // Core types
  AgentEvent,
  MethodTypes,
  TokenUsage,
  ToolResult,
  ConfirmRequest,
  InputRequest,

  // Individual event types (for type narrowing)
  AgentStartEvent,
  AgentEndEvent,
  AgentAbortEvent,
  AgentRecoveredEvent,
  MessageStartEvent,
  MessageDeltaEvent,
  MessageQueuedEvent,
  MessageAppliedEvent,
  ThinkingStartEvent,
  ThinkingDeltaEvent,
  ToolExecutionStartEvent,
  ToolExecutionEndEvent,
  TurnEndEvent,
  ErrorEvent,
  UsageUpdateEvent,
  StatusUpdateEvent,
  ContextDiscoveredEvent,
  SkillLoadedEvent,
  SubAgentEventEvent,

  // Common param/result types
  SessionStartParams,
  SessionStartResult,
  AgentStateResult,
  AgentPromptParams,
  AgentPromptResult,
  ModelsListResult,
  ModelSetResult,
} from "../sdk/protocol.js";

// ── JSON-RPC types (advanced/debug) ─────────────────────────────────
export type {
  JsonRpcRequest,
  JsonRpcNotification,
  JsonRpcResponse,
  JsonRpcErrorData,
  JsonRpcMessage,
} from "./rpc/types.js";
export { ErrorCodes } from "./rpc/types.js";
