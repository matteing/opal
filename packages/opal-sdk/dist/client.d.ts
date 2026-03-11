/**
 * OpalClient — Typed, bidirectional JSON-RPC 2.0 client for opal-server.
 *
 * Provides fully typed `request<M>()` with inference from the protocol's
 * `MethodTypes` map. Server→client callbacks and agent event streaming
 * are wired through the underlying RpcConnection.
 */
import { RpcConnection } from "./rpc/connection.js";
import type { Disposable } from "./transport/transport.js";
import type { MethodTypes, AgentEvent } from "./protocol.js";
/** Server→client method names (we handle these). */
type IncomingMethod = "client/confirm" | "client/input" | "client/ask_user";
/** Client→server method names (we send these). */
type OutgoingMethod = Exclude<keyof MethodTypes, IncomingMethod>;
/** Typed handler for a server→client method. */
export type ServerMethodHandler<M extends IncomingMethod> = (params: MethodTypes[M]["params"]) => Promise<MethodTypes[M]["result"]>;
/** Handler for incoming agent events. */
export type AgentEventHandler = (event: AgentEvent) => void;
export declare class OpalClient {
    #private;
    constructor(rpc: RpcConnection);
    /**
     * Send a typed JSON-RPC request to the server.
     *
     * Params and result types are inferred from the method string.
     * For methods with empty params (e.g., "opal/ping"), params can be omitted.
     */
    request<M extends OutgoingMethod>(method: M, ...args: MethodTypes[M]["params"] extends Record<string, never> ? [params?: MethodTypes[M]["params"], timeoutMs?: number] : [params: MethodTypes[M]["params"], timeoutMs?: number]): Promise<MethodTypes[M]["result"]>;
    /** Register a handler for incoming agent events. Returns cleanup handle. */
    onEvent(handler: AgentEventHandler): Disposable;
    /** Register a typed handler for a server→client method. */
    addServerMethod<M extends IncomingMethod>(method: M, handler: ServerMethodHandler<M>): Disposable;
    /** Liveness check — resolves if the server responds within the timeout. */
    ping(timeoutMs?: number): Promise<void>;
    /** Whether the client is closed. */
    get closed(): boolean;
    /** Close the client and release resources. */
    close(): void;
    [Symbol.dispose](): void;
}
export {};
//# sourceMappingURL=client.d.ts.map