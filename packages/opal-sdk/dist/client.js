/**
 * OpalClient — Typed, bidirectional JSON-RPC 2.0 client for opal-server.
 *
 * Provides fully typed `request<M>()` with inference from the protocol's
 * `MethodTypes` map. Server→client callbacks and agent event streaming
 * are wired through the underlying RpcConnection.
 */
import { ClientClosedError } from "./errors.js";
// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------
export class OpalClient {
    #rpc;
    #eventHandlers = new Set();
    #notifSub;
    constructor(rpc) {
        this.#rpc = rpc;
        // Route agent/event notifications to event handlers
        this.#notifSub = rpc.onNotification((method, params) => {
            if (method === "agent/event") {
                const raw = params;
                const wireType = raw.type;
                const camelType = wireType.replace(/_([a-z])/g, (_, c) => c.toUpperCase());
                const event = { ...raw, type: camelType };
                for (const handler of this.#eventHandlers) {
                    handler(event);
                }
            }
        });
    }
    /**
     * Send a typed JSON-RPC request to the server.
     *
     * Params and result types are inferred from the method string.
     * For methods with empty params (e.g., "opal/ping"), params can be omitted.
     */
    async request(method, ...args) {
        if (this.#rpc.closed)
            throw new ClientClosedError();
        const [params, timeoutMs] = args;
        return this.#rpc.request(method, params ?? {}, timeoutMs);
    }
    /** Register a handler for incoming agent events. Returns cleanup handle. */
    onEvent(handler) {
        this.#eventHandlers.add(handler);
        return { dispose: () => this.#eventHandlers.delete(handler) };
    }
    /** Register a typed handler for a server→client method. */
    addServerMethod(method, handler) {
        return this.#rpc.addMethod(method, (params) => handler(params));
    }
    /** Liveness check — resolves if the server responds within the timeout. */
    async ping(timeoutMs = 5000) {
        await this.request("opal/ping", {}, timeoutMs);
    }
    /** Whether the client is closed. */
    get closed() {
        return this.#rpc.closed;
    }
    /** Close the client and release resources. */
    close() {
        this.#notifSub.dispose();
        this.#eventHandlers.clear();
        this.#rpc.close();
    }
    [Symbol.dispose]() {
        this.close();
    }
}
//# sourceMappingURL=client.js.map