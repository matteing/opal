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
export { createSession, Session } from "./session.js";
// ── Stream ──────────────────────────────────────────────────────────
export { AgentStream } from "./stream.js";
// ── Event Matching ──────────────────────────────────────────────────
export { matchEvent, matchEventPartial, isEventType, assertNever, } from "./match.js";
// ── Errors ──────────────────────────────────────────────────────────
export { OpalError, ConnectionError, TimeoutError, RpcError, AbortError, ClientClosedError, isOpalError, isErrorCode, } from "./errors.js";
// ── Low-level (advanced usage) ──────────────────────────────────────
export { OpalClient } from "./client.js";
export { RpcConnection, } from "./rpc/connection.js";
export { StdioTransport } from "./transport/stdio.js";
export { createMemoryTransport } from "./transport/memory.js";
export { resolveServer } from "./resolve.js";
export { snakeToCamel, camelToSnake } from "./transforms.js";
// ── Protocol types (auto-generated) ─────────────────────────────────
// Re-export the method constants and all type definitions consumers need.
export { Methods } from "./protocol.js";
export { ErrorCodes } from "./rpc/types.js";
//# sourceMappingURL=index.js.map