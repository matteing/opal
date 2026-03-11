/**
 * Structured error hierarchy for the Opal SDK.
 *
 * All errors extend OpalError with a `.code` discriminant for programmatic
 * handling via switch statements or type predicates.
 *
 * @example
 * ```ts
 * try {
 *   for await (const event of session.prompt("hello")) { ... }
 * } catch (e) {
 *   if (e instanceof OpalError) {
 *     switch (e.code) {
 *       case "CONNECTION_LOST": console.error("Server died:", e.stderr);  break;
 *       case "TIMEOUT":         console.error(`Timed out after ${e.timeoutMs}ms`); break;
 *       case "SERVER_ERROR":    console.error(`RPC [${e.rpcCode}]: ${e.message}`); break;
 *       case "ABORTED":         console.log("Cancelled"); break;
 *       case "CLIENT_CLOSED":   console.log("Already closed"); break;
 *     }
 *   }
 * }
 * ```
 */
// ---------------------------------------------------------------------------
// Base class
// ---------------------------------------------------------------------------
/** Base error for all Opal SDK errors. */
export class OpalError extends Error {
    code;
    cause;
    constructor(code, message, opts) {
        super(message);
        this.code = code;
        this.name = "OpalError";
        if (opts?.cause)
            this.cause = opts.cause;
    }
}
// ---------------------------------------------------------------------------
// Concrete errors
// ---------------------------------------------------------------------------
/** Server process exited or pipe broken. */
export class ConnectionError extends OpalError {
    code = "CONNECTION_LOST";
    exitCode;
    signal;
    stderr;
    constructor(exitCode, signal, stderr) {
        super("CONNECTION_LOST", `opal-server exited (code=${exitCode}, signal=${signal})`);
        this.name = "ConnectionError";
        this.exitCode = exitCode;
        this.signal = signal;
        this.stderr = stderr;
    }
}
/** RPC request timed out. */
export class TimeoutError extends OpalError {
    code = "TIMEOUT";
    method;
    timeoutMs;
    constructor(method, timeoutMs) {
        super("TIMEOUT", `${method}: timed out after ${timeoutMs}ms`);
        this.name = "TimeoutError";
        this.method = method;
        this.timeoutMs = timeoutMs;
    }
}
/** Server returned a JSON-RPC error response. */
export class RpcError extends OpalError {
    code = "SERVER_ERROR";
    method;
    rpcCode;
    data;
    constructor(method, rpcCode, message, data) {
        super("SERVER_ERROR", message);
        this.name = "RpcError";
        this.method = method;
        this.rpcCode = rpcCode;
        this.data = data;
    }
}
/** Agent run was cancelled. */
export class AbortError extends OpalError {
    code = "ABORTED";
    constructor(message = "Operation aborted") {
        super("ABORTED", message);
        this.name = "AbortError";
    }
}
/** Client was used after close(). */
export class ClientClosedError extends OpalError {
    code = "CLIENT_CLOSED";
    constructor() {
        super("CLIENT_CLOSED", "Client is closed");
        this.name = "ClientClosedError";
    }
}
// ---------------------------------------------------------------------------
// Type predicates
// ---------------------------------------------------------------------------
/** Narrow any caught value to an {@link OpalError}. */
export function isOpalError(err) {
    return err instanceof OpalError;
}
/** Narrow to a specific error by code. */
export function isErrorCode(err, code) {
    return err instanceof OpalError && err.code === code;
}
//# sourceMappingURL=errors.js.map