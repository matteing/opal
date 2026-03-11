/**
 * Bidirectional JSON-RPC 2.0 connection.
 *
 * Wraps a Transport with request/response id correlation, typed notification
 * dispatch, and server-initiated method handling. Case transforms (snake↔camel)
 * are applied at the boundary so all SDK code operates in camelCase.
 */
import type { Transport, Disposable } from "../transport/transport.js";
/** Handler for a server-initiated RPC method. */
export type MethodHandler = (params: unknown) => Promise<unknown>;
/** Handler for a notification. */
export type NotificationHandler = (method: string, params: unknown) => void;
/** Callback for observing raw RPC traffic. */
export interface RpcObserver {
    onOutgoing?: (message: unknown) => void;
    onIncoming?: (message: unknown) => void;
}
export declare class RpcConnection {
    #private;
    constructor(transport: Transport, observer?: RpcObserver);
    /** Send a JSON-RPC request and await the response. */
    request(method: string, params?: unknown, timeoutMs?: number): Promise<unknown>;
    /** Register a handler for a server→client method. */
    addMethod(method: string, handler: MethodHandler): Disposable;
    /** Register a handler for notifications. */
    onNotification(handler: NotificationHandler): Disposable;
    /** Whether the connection is closed. */
    get closed(): boolean;
    /** Close the connection and reject pending requests. */
    close(): void;
    [Symbol.dispose](): void;
}
//# sourceMappingURL=connection.d.ts.map