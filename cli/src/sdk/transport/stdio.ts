/**
 * Stdio transport — spawns an Elixir server child process and communicates
 * via newline-delimited JSON on stdin/stdout.
 */

import { spawn, type ChildProcess } from "node:child_process";
import { createInterface, type Interface } from "node:readline";
import { resolveServer, type ServerResolution } from "../resolve.js";
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
export class StdioTransport implements Transport {
  readonly #proc: ChildProcess;
  readonly #rl: Interface;
  readonly #messageHandlers = new Set<(data: string) => void>();
  readonly #closeHandlers = new Set<(reason?: Error) => void>();
  readonly #errorHandlers = new Set<(error: Error) => void>();
  readonly #cleanup: () => void;
  #state: TransportState = "connecting";

  constructor(opts: StdioTransportOptions = {}) {
    const { cmd, args, cwd } = resolveCommand(opts);

    this.#proc = spawn(cmd, args, {
      stdio: ["pipe", "pipe", "pipe"],
      cwd,
      // .bat/.cmd files on Windows require shell execution
      shell: process.platform === "win32",
    });
    this.#rl = createInterface({ input: this.#proc.stdout! });

    // Mark open once the readline interface is ready
    this.#state = "open";

    // Route each stdout line to message handlers
    this.#rl.on("line", (line: string) => {
      if (!line.trim()) return;
      for (const handler of this.#messageHandlers) {
        handler(line);
      }
    });

    // Stderr forwarding
    this.#proc.stderr?.on("data", (chunk: Buffer) => {
      opts.onStderr?.(chunk.toString());
    });

    // Process exit → close transport
    this.#proc.on("exit", (code, signal) => {
      if (this.#state === "closed") return;
      this.#state = "closed";
      const reason =
        code !== 0 ? new Error(`opal-server exited (code=${code}, signal=${signal})`) : undefined;
      this.#fireClose(reason);
    });

    // Prevent orphan Elixir VM on parent exit
    const exitHandler = () => this.close();
    process.on("exit", exitHandler);
    this.#cleanup = () => process.removeListener("exit", exitHandler);
    this.#proc.on("exit", () => this.#cleanup());
  }

  /** Current connection state. */
  get state(): TransportState {
    return this.#state;
  }

  /** Send a serialized message string. Throws if not open. */
  send(data: string): void {
    if (this.#state !== "open") {
      throw new Error(`Cannot send in "${this.#state}" state`);
    }
    try {
      this.#proc.stdin!.write(data + "\n");
    } catch (err) {
      for (const handler of this.#errorHandlers) {
        handler(err instanceof Error ? err : new Error(String(err)));
      }
    }
  }

  /** Register a handler for incoming messages. */
  onMessage(handler: (data: string) => void): Disposable {
    this.#messageHandlers.add(handler);
    return { dispose: () => this.#messageHandlers.delete(handler) };
  }

  /** Register a handler for transport close. Fires once. */
  onClose(handler: (reason?: Error) => void): Disposable {
    this.#closeHandlers.add(handler);
    return { dispose: () => this.#closeHandlers.delete(handler) };
  }

  /** Register a handler for non-fatal errors. */
  onError(handler: (error: Error) => void): Disposable {
    this.#errorHandlers.add(handler);
    return { dispose: () => this.#errorHandlers.delete(handler) };
  }

  /** Gracefully shut down. Idempotent. */
  close(): void {
    if (this.#state === "closed") return;
    this.#state = "closed";
    this.#cleanup();
    this.#rl.close();
    this.#proc.kill();
    this.#fireClose();
  }

  /** Symbol.dispose support for `using` syntax. */
  [Symbol.dispose](): void {
    this.close();
  }

  #fireClose(reason?: Error): void {
    for (const handler of this.#closeHandlers) {
      handler(reason);
    }
    this.#closeHandlers.clear();
  }
}

/** Resolve the command, args, and cwd for spawning the server process. */
function resolveCommand(opts: StdioTransportOptions): {
  cmd: string;
  args: string[];
  cwd: string | undefined;
} {
  if (opts.serverPath) {
    return { cmd: opts.serverPath, args: opts.args ?? [], cwd: opts.cwd };
  }

  const resolved = opts.server ?? resolveServer();
  return {
    cmd: resolved.command,
    args: [...resolved.args, ...(opts.args ?? [])],
    cwd: opts.cwd ?? resolved.cwd,
  };
}
