/**
 * Shared test helpers for tests that spawn a mock child process (OpalClient / Session).
 *
 * Provides:
 *  - createMockProcess()   – fake child_process with piped stdin/stdout/stderr
 *  - respond / respondError / sendEvent – push JSON-RPC frames onto stdout
 *  - capturingWrites()     – attach a write-spy to stdin and return helpers
 *  - tick()                – await a short setTimeout (default 10 ms)
 *  - SESSION_DEFAULTS      – minimal session/start result payload
 */
import { vi } from "vitest";
import { EventEmitter, Readable, Writable } from "node:stream";

// ---------------------------------------------------------------------------
// Mock child process
// ---------------------------------------------------------------------------

export type MockProcess = EventEmitter & {
  stdin: Writable;
  stdout: Readable;
  stderr: Readable;
  kill: ReturnType<typeof vi.fn>;
  pid: number;
};

export function createMockProcess(): MockProcess {
  const stdin = new Writable({
    write(_chunk, _enc, cb) {
      cb();
    },
  });
  const stdout = new Readable({ read() {} });
  const stderr = new Readable({ read() {} });

  const proc = new EventEmitter() as MockProcess;
  proc.stdin = stdin;
  proc.stdout = stdout;
  proc.stderr = stderr;
  proc.kill = vi.fn();
  proc.pid = 12345;
  return proc;
}

// ---------------------------------------------------------------------------
// JSON-RPC helpers — push well-formed frames onto a mock process's stdout
// ---------------------------------------------------------------------------

function push(proc: MockProcess, obj: unknown) {
  proc.stdout.push(JSON.stringify(obj) + "\n");
}

/** Send a successful JSON-RPC response. */
export function respond(proc: MockProcess, id: number, result: unknown) {
  push(proc, { jsonrpc: "2.0", id, result });
}

/** Send a JSON-RPC error response. */
export function respondError(proc: MockProcess, id: number, code: number, message: string) {
  push(proc, { jsonrpc: "2.0", id, error: { code, message } });
}

/** Send a JSON-RPC notification (agent/event). */
export function sendEvent(proc: MockProcess, params: unknown) {
  push(proc, { jsonrpc: "2.0", method: "agent/event", params });
}

/** Send a JSON-RPC server→client request (e.g. client/confirm). */
export function sendRequest(proc: MockProcess, id: number, method: string, params: unknown) {
  push(proc, { jsonrpc: "2.0", id, method, params });
}

// ---------------------------------------------------------------------------
// Write-capturing helpers
// ---------------------------------------------------------------------------

export interface CapturedWrites {
  /** Raw strings written to stdin. */
  raw: string[];
  /** Parse every raw write as JSON, returning null for unparseable entries. */
  parsed: () => Array<Record<string, unknown> | null>;
  /** Return the last write parsed as JSON. */
  lastRequest: () => Record<string, unknown>;
  /** Find the first write whose `method` matches. */
  findByMethod: (method: string) => Record<string, unknown> | undefined;
  /** Clear captured writes (call in beforeEach). */
  clear: () => void;
}

/**
 * Override `proc.stdin.write` to capture outgoing JSON-RPC messages.
 * Returns a `CapturedWrites` object with query helpers.
 */
export function capturingWrites(proc: MockProcess): CapturedWrites {
  const raw: string[] = [];

  proc.stdin.write = function (chunk: unknown, ...args: unknown[]) {
    raw.push(String(chunk));
    const cb = args.find((a) => typeof a === "function") as (() => void) | undefined;
    cb?.();
    return true;
  } as never;

  const parsed = () =>
    raw.map((w) => {
      try {
        return JSON.parse(w.trim()) as Record<string, unknown>;
      } catch {
        return null;
      }
    });

  return {
    raw,
    parsed,
    lastRequest: () => {
      const last = raw[raw.length - 1];
      return JSON.parse(last.trim()) as Record<string, unknown>;
    },
    findByMethod: (method: string) =>
      parsed().find((m) => m?.method === method) as Record<string, unknown> | undefined,
    clear: () => {
      raw.length = 0;
    },
  };
}

// ---------------------------------------------------------------------------
// Timing helper
// ---------------------------------------------------------------------------

/** Await a short delay to let async operations settle. */
export function tick(ms = 10) {
  return new Promise<void>((r) => setTimeout(r, ms));
}

// ---------------------------------------------------------------------------
// Default session/start response
// ---------------------------------------------------------------------------

export const SESSION_DEFAULTS = {
  session_id: "s1",
  session_dir: "/tmp/s1",
  context_files: [],
  available_skills: [],
  mcp_servers: [],
  node_name: "opal@test",
  auth: { provider: "copilot", providers: [], status: "ready" },
};
