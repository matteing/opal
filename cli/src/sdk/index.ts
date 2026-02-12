// SDK public API
export { OpalClient, type OpalClientOptions } from "./client.js";
export { Session, type SessionOptions } from "./session.js";
export { resolveServer, type ServerResolution } from "./resolve.js";
export { snakeToCamel, camelToSnake } from "./transforms.js";

// Re-export all protocol types
export type {
  AgentEvent,
  AgentStartEvent,
  AgentEndEvent,
  AgentAbortEvent,
  MessageStartEvent,
  MessageDeltaEvent,
  ThinkingStartEvent,
  ThinkingDeltaEvent,
  ToolExecutionStartEvent,
  ToolExecutionEndEvent,
  TurnEndEvent,
  ErrorEvent,
  SkillLoadedEvent,
  TokenUsage,
  ToolResult,
  ConfirmRequest,
  InputRequest,
  MethodTypes,
  SessionStartParams,
  SessionStartResult,
  AgentStateResult,
} from "./protocol.js";

export { Methods } from "./protocol.js";

