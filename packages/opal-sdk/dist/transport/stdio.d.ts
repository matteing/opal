/**
 * Stdio transport — spawns an Elixir server child process and communicates
 * via newline-delimited JSON on stdin/stdout.
 */
import { type ServerResolution } from "../resolve.js";
import type { Transport, TransportState, Disposable } from "./transport.js";
/** Options for constructing a StdioTransport. */
export interface StdioTransportOptions {
    /** Override server resolution with a specific command + args. */
    server?: ServerResolution;
    /** Direct path to the opal-server binary. */
    serverPath?: string;
    /** Extra args appended to the server command. */
    args?: string[];
    /** Working directory for the server process. */
    cwd?: string;
    /** Called with server stderr chunks. */
    onStderr?: (data: string) => void;
}
/**
 * Transport that communicates with an opal-server child process over stdio.
 *
 * Each line on stdout is treated as a single JSON message. Messages are
 * written to stdin as JSON followed by a newline.
 */
export declare class StdioTransport implements Transport {
    #private;
    constructor(opts?: StdioTransportOptions);
    /** Current connection state. */
    get state(): TransportState;
    /** Send a serialized message string. Throws if not open. */
    send(data: string): void;
    /** Register a handler for incoming messages. */
    onMessage(handler: (data: string) => void): Disposable;
    /** Register a handler for transport close. Fires once. */
    onClose(handler: (reason?: Error) => void): Disposable;
    /** Register a handler for non-fatal errors. */
    onError(handler: (error: Error) => void): Disposable;
    /** Gracefully shut down. Idempotent. */
    close(): void;
    /** Symbol.dispose support for `using` syntax. */
    [Symbol.dispose](): void;
}
//# sourceMappingURL=stdio.d.ts.map