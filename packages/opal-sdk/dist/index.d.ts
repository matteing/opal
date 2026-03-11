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
export { createSession, Session, type SessionOptions } from "./session.js";
export { AgentStream, type FinalMessage } from "./stream.js";
export { matchEvent, matchEventPartial, isEventType, assertNever, type AgentEventType, type EventOfType, type AgentEventVisitor, type PartialVisitor, } from "./match.js";
export { OpalError, ConnectionError, TimeoutError, RpcError, AbortError, ClientClosedError, isOpalError, isErrorCode, type OpalErrorCode, } from "./errors.js";
export { OpalClient, type ServerMethodHandler, type AgentEventHandler } from "./client.js";
export { RpcConnection, type RpcObserver, type MethodHandler, type NotificationHandler, } from "./rpc/connection.js";
export { type Transport, type TransportState, type Disposable } from "./transport/transport.js";
export { StdioTransport, type StdioTransportOptions } from "./transport/stdio.js";
export { createMemoryTransport } from "./transport/memory.js";
export { resolveServer, type ServerResolution } from "./resolve.js";
export { snakeToCamel, camelToSnake } from "./transforms.js";
export { Methods } from "./protocol.js";
export type { AgentEvent, MethodTypes, TokenUsage, ToolResult, ConfirmRequest, InputRequest, AgentStartEvent, AgentEndEvent, AgentAbortEvent, AgentRecoveredEvent, MessageStartEvent, MessageDeltaEvent, MessageQueuedEvent, MessageAppliedEvent, ThinkingStartEvent, ThinkingDeltaEvent, ToolExecutionStartEvent, ToolExecutionEndEvent, TurnEndEvent, ErrorEvent, UsageUpdateEvent, StatusUpdateEvent, ContextDiscoveredEvent, SkillLoadedEvent, SubAgentEventEvent, SessionStartParams, SessionStartResult, AgentStateResult, AgentPromptParams, AgentPromptResult, ModelsListResult, ModelSetResult, OpalConfigGetResult, OpalConfigSetParams, OpalConfigSetResult, } from "./protocol.js";
export type { JsonRpcRequest, JsonRpcNotification, JsonRpcResponse, JsonRpcErrorData, JsonRpcMessage, } from "./rpc/types.js";
export { ErrorCodes } from "./rpc/types.js";
//# sourceMappingURL=index.d.ts.map