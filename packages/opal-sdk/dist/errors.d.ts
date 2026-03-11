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
/** Union of all error codes for exhaustive switch handling. */
export type OpalErrorCode = "CONNECTION_LOST" | "TIMEOUT" | "SERVER_ERROR" | "ABORTED" | "CLIENT_CLOSED";
/** Base error for all Opal SDK errors. */
export declare class OpalError extends Error {
    readonly code: OpalErrorCode;
    readonly cause?: Error;
    constructor(code: OpalErrorCode, message: string, opts?: {
        cause?: Error;
    });
}
/** Server process exited or pipe broken. */
export declare class ConnectionError extends OpalError {
    readonly code: "CONNECTION_LOST";
    readonly exitCode: number | null;
    readonly signal: string | null;
    readonly stderr: string;
    constructor(exitCode: number | null, signal: string | null, stderr: string);
}
/** RPC request timed out. */
export declare class TimeoutError extends OpalError {
    readonly code: "TIMEOUT";
    readonly method: string;
    readonly timeoutMs: number;
    constructor(method: string, timeoutMs: number);
}
/** Server returned a JSON-RPC error response. */
export declare class RpcError extends OpalError {
    readonly code: "SERVER_ERROR";
    readonly method: string;
    readonly rpcCode: number;
    readonly data?: unknown;
    constructor(method: string, rpcCode: number, message: string, data?: unknown);
}
/** Agent run was cancelled. */
export declare class AbortError extends OpalError {
    readonly code: "ABORTED";
    constructor(message?: string);
}
/** Client was used after close(). */
export declare class ClientClosedError extends OpalError {
    readonly code: "CLIENT_CLOSED";
    constructor();
}
/** Narrow any caught value to an {@link OpalError}. */
export declare function isOpalError(err: unknown): err is OpalError;
/** Narrow to a specific error by code. */
export declare function isErrorCode<C extends OpalErrorCode>(err: unknown, code: C): err is OpalError & {
    code: C;
};
//# sourceMappingURL=errors.d.ts.map