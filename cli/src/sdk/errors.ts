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
// Error codes
// ---------------------------------------------------------------------------

/** Union of all error codes for exhaustive switch handling. */
export type OpalErrorCode =
  | "CONNECTION_LOST"
  | "TIMEOUT"
  | "SERVER_ERROR"
  | "ABORTED"
  | "CLIENT_CLOSED";

// ---------------------------------------------------------------------------
// Base class
// ---------------------------------------------------------------------------

/** Base error for all Opal SDK errors. */
export class OpalError extends Error {
  readonly code: OpalErrorCode;
  readonly cause?: Error;

  constructor(code: OpalErrorCode, message: string, opts?: { cause?: Error }) {
    super(message);
    this.code = code;
    this.name = "OpalError";
    if (opts?.cause) this.cause = opts.cause;
  }
}

// ---------------------------------------------------------------------------
// Concrete errors
// ---------------------------------------------------------------------------

/** Server process exited or pipe broken. */
export class ConnectionError extends OpalError {
  readonly code = "CONNECTION_LOST" as const;
  readonly exitCode: number | null;
  readonly signal: string | null;
  readonly stderr: string;

  constructor(exitCode: number | null, signal: string | null, stderr: string) {
    super(
      "CONNECTION_LOST",
      `opal-server exited (code=${exitCode}, signal=${signal})`,
    );
    this.name = "ConnectionError";
    this.exitCode = exitCode;
    this.signal = signal;
    this.stderr = stderr;
  }
}

/** RPC request timed out. */
export class TimeoutError extends OpalError {
  readonly code = "TIMEOUT" as const;
  readonly method: string;
  readonly timeoutMs: number;

  constructor(method: string, timeoutMs: number) {
    super("TIMEOUT", `${method}: timed out after ${timeoutMs}ms`);
    this.name = "TimeoutError";
    this.method = method;
    this.timeoutMs = timeoutMs;
  }
}

/** Server returned a JSON-RPC error response. */
export class RpcError extends OpalError {
  readonly code = "SERVER_ERROR" as const;
  readonly method: string;
  readonly rpcCode: number;
  readonly data?: unknown;

  constructor(
    method: string,
    rpcCode: number,
    message: string,
    data?: unknown,
  ) {
    super("SERVER_ERROR", message);
    this.name = "RpcError";
    this.method = method;
    this.rpcCode = rpcCode;
    this.data = data;
  }
}

/** Agent run was cancelled. */
export class AbortError extends OpalError {
  readonly code = "ABORTED" as const;

  constructor(message: string = "Operation aborted") {
    super("ABORTED", message);
    this.name = "AbortError";
  }
}

/** Client was used after close(). */
export class ClientClosedError extends OpalError {
  readonly code = "CLIENT_CLOSED" as const;

  constructor() {
    super("CLIENT_CLOSED", "Client is closed");
    this.name = "ClientClosedError";
  }
}

// ---------------------------------------------------------------------------
// Type predicates
// ---------------------------------------------------------------------------

/** Narrow any caught value to an {@link OpalError}. */
export function isOpalError(err: unknown): err is OpalError {
  return err instanceof OpalError;
}

/** Narrow to a specific error by code. */
export function isErrorCode<C extends OpalErrorCode>(
  err: unknown,
  code: C,
): err is OpalError & { code: C } {
  return err instanceof OpalError && err.code === code;
}
