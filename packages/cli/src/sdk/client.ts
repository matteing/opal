import { spawn, type ChildProcess } from "node:child_process";
import { createInterface, type Interface } from "node:readline";
import { EventEmitter } from "node:events";
import { resolveServer, type ServerResolution } from "./resolve.js";
import { snakeToCamel, camelToSnake } from "./transforms.js";
import type { MethodTypes, AgentEvent } from "./protocol.js";

// --- JSON-RPC types ---

interface JsonRpcRequest {
  jsonrpc: "2.0";
  id: number;
  method: string;
  params: Record<string, unknown>;
}

interface JsonRpcResponse {
  jsonrpc: "2.0";
  id: number;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}

interface JsonRpcNotification {
  jsonrpc: "2.0";
  method: string;
  params: Record<string, unknown>;
}

type JsonRpcMessage = JsonRpcResponse | JsonRpcNotification | JsonRpcRequest;

function isResponse(msg: JsonRpcMessage): msg is JsonRpcResponse {
  return "id" in msg && !("method" in msg);
}

function isNotification(msg: JsonRpcMessage): msg is JsonRpcNotification {
  return "method" in msg && !("id" in msg);
}

function isServerRequest(msg: JsonRpcMessage): msg is JsonRpcRequest {
  return "method" in msg && "id" in msg;
}

// --- Pending request tracking ---

interface PendingRequest {
  resolve: (result: unknown) => void;
  reject: (error: Error) => void;
}

// --- RPC message log entry ---

export type RpcDirection = "outgoing" | "incoming";

export interface RpcMessageEntry {
  id: number;
  direction: RpcDirection;
  timestamp: number;
  /** Raw JSON-RPC payload */
  raw: unknown;
  /** RPC method name (absent for bare responses) */
  method?: string;
  /** "request" | "response" | "notification" | "error" */
  kind: "request" | "response" | "notification" | "error";
}

// --- Client options ---

export interface OpalClientOptions {
  /** Override server resolution with a specific command + args */
  server?: ServerResolution;
  serverPath?: string;
  /** Extra args passed to opal-server */
  args?: string[];
  /** Working directory for the server process */
  cwd?: string;
  /** Handler for server→client requests */
  onServerRequest?: (
    method: string,
    params: Record<string, unknown>,
  ) => Promise<Record<string, unknown>>;
}

// --- OpalClient ---

export class OpalClient extends EventEmitter {
  private process: ChildProcess;
  private rl: Interface;
  private nextId = 1;
  private rpcSeq = 0;
  private pending = new Map<number, PendingRequest>();
  private onServerRequest?: OpalClientOptions["onServerRequest"];
  private closed = false;

  constructor(opts: OpalClientOptions = {}) {
    super();
    this.onServerRequest = opts.onServerRequest;

    // Resolve server: explicit path > explicit resolution > auto-detect
    let cmd: string;
    let args: string[];
    let cwd: string | undefined = opts.cwd;

    if (opts.serverPath) {
      cmd = opts.serverPath;
      args = opts.args ?? [];
    } else if (opts.server) {
      cmd = opts.server.command;
      args = [...opts.server.args, ...(opts.args ?? [])];
      cwd = cwd ?? opts.server.cwd;
    } else {
      const resolved = resolveServer();
      cmd = resolved.command;
      args = [...resolved.args, ...(opts.args ?? [])];
      cwd = cwd ?? resolved.cwd;
    }

    this.process = spawn(cmd, args, {
      stdio: ["pipe", "pipe", "pipe"],
      cwd,
    });

    this.rl = createInterface({ input: this.process.stdout! });
    this.rl.on("line", (line: string) => this.handleLine(line));

    const stderrChunks: string[] = [];
    this.process.stderr?.on("data", (chunk: Buffer) => {
      const text = chunk.toString();
      stderrChunks.push(text);
      this.emit("stderr", text);
    });

    this.process.on("exit", (code, signal) => {
      this.closed = true;
      const stderr = stderrChunks.join("").trim();
      const detail = stderr ? `\n\nServer stderr:\n${stderr.slice(-2000)}` : "";
      this.rejectAll(new Error(`opal-server exited (code=${code}, signal=${signal})${detail}`));
      this.emit("exit", code, signal);
    });

    // Ensure the server process is killed when the parent exits (e.g. Ctrl+C).
    // Without this, the Elixir VM can linger as an orphan process.
    const cleanup = () => this.close();
    process.on("exit", cleanup);
    this.process.on("exit", () => process.removeListener("exit", cleanup));
  }

  /**
   * Send a typed JSON-RPC request.
   */
  async request<M extends keyof MethodTypes>(
    method: M,
    params: MethodTypes[M]["params"],
    timeoutMs?: number,
  ): Promise<MethodTypes[M]["result"]> {
    if (this.closed) throw new Error("Client is closed");

    const id = this.nextId++;
    const wireParams = camelToSnake(params) as Record<string, unknown>;

    const msg: JsonRpcRequest = {
      jsonrpc: "2.0",
      id,
      method,
      params: wireParams,
    };

    this.send(msg);

    return new Promise<MethodTypes[M]["result"]>((resolve, reject) => {
      let timer: ReturnType<typeof setTimeout> | undefined;

      const pending: PendingRequest = {
        resolve: (v) => {
          if (timer) clearTimeout(timer);
          (resolve as (v: unknown) => void)(v);
        },
        reject: (e) => {
          if (timer) clearTimeout(timer);
          reject(e);
        },
      };

      this.pending.set(id, pending);

      if (timeoutMs != null && timeoutMs > 0) {
        timer = setTimeout(() => {
          if (this.pending.delete(id)) {
            reject(new Error(`Request "${method}" timed out after ${timeoutMs}ms`));
          }
        }, timeoutMs);
      }
    });
  }

  /**
   * Register a handler for agent/event notifications.
   */
  onEvent(handler: (event: AgentEvent) => void): void {
    this.on("agent/event", handler);
  }

  /**
   * Register a handler for raw notifications.
   */
  onNotification(handler: (method: string, params: Record<string, unknown>) => void): void {
    this.on("notification", handler);
  }

  /**
   * Close the client and kill the server process.
   */
  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.rl.close();
    this.process.kill();
    this.rejectAll(new Error("Client closed"));
  }

  /**
   * Liveness check. Resolves if the server responds within the timeout.
   */
  async ping(timeoutMs = 5000): Promise<void> {
    await this.request("opal/ping", {} as Record<string, never>, timeoutMs);
  }

  // --- Private ---

  private send(msg: JsonRpcRequest | JsonRpcResponse): void {
    this.process.stdin!.write(JSON.stringify(msg) + "\n");
    const entry: RpcMessageEntry = {
      id: ++this.rpcSeq,
      direction: "outgoing",
      timestamp: Date.now(),
      raw: msg,
      method: "method" in msg ? (msg as JsonRpcRequest).method : undefined,
      kind: "method" in msg ? "request" : "response",
    };
    this.emit("rpc:message", entry);
  }

  private handleLine(line: string): void {
    if (!line.trim()) return;

    let msg: JsonRpcMessage;
    try {
      msg = JSON.parse(line) as JsonRpcMessage;
    } catch {
      this.emit("parseError", line);
      return;
    }

    // Emit raw incoming RPC message for debug panel
    const entry: RpcMessageEntry = {
      id: ++this.rpcSeq,
      direction: "incoming",
      timestamp: Date.now(),
      raw: msg,
      method: "method" in msg ? (msg as { method: string }).method : undefined,
      kind: isResponse(msg)
        ? msg.error
          ? "error"
          : "response"
        : isNotification(msg)
          ? "notification"
          : "request",
    };
    this.emit("rpc:message", entry);

    if (isResponse(msg)) {
      this.handleResponse(msg);
    } else if (isServerRequest(msg)) {
      void this.handleServerRequest(msg);
    } else if (isNotification(msg)) {
      this.handleNotification(msg);
    }
  }

  private handleResponse(msg: JsonRpcResponse): void {
    const pending = this.pending.get(msg.id);
    if (!pending) return;
    this.pending.delete(msg.id);

    if (msg.error) {
      pending.reject(new Error(`RPC error ${msg.error.code}: ${msg.error.message}`));
    } else {
      pending.resolve(snakeToCamel(msg.result));
    }
  }

  private handleNotification(msg: JsonRpcNotification): void {
    const params = snakeToCamel(msg.params) as Record<string, unknown>;
    this.emit("notification", msg.method, params);

    if (msg.method === "agent/event") {
      // Transform snake_case type to camelCase
      const wireType = msg.params.type as string;
      const camelType = wireType.replace(/_([a-z])/g, (_, c: string) => c.toUpperCase());
      const event = { ...params, type: camelType } as unknown as AgentEvent;
      this.emit("agent/event", event);
    }
  }

  private async handleServerRequest(msg: JsonRpcRequest): Promise<void> {
    const params = snakeToCamel(msg.params) as Record<string, unknown>;

    if (this.onServerRequest) {
      try {
        const result = await this.onServerRequest(msg.method, params);
        const response: JsonRpcResponse = {
          jsonrpc: "2.0",
          id: msg.id,
          result: camelToSnake(result),
        };
        this.send(response);
      } catch (err) {
        const response: JsonRpcResponse = {
          jsonrpc: "2.0",
          id: msg.id,
          error: {
            code: -32000,
            message: err instanceof Error ? err.message : String(err),
          },
        };
        this.send(response);
      }
    } else {
      // No handler — reject with method not found
      const response: JsonRpcResponse = {
        jsonrpc: "2.0",
        id: msg.id,
        error: { code: -32601, message: `No handler for ${msg.method}` },
      };
      this.send(response);
    }
  }

  private rejectAll(error: Error): void {
    for (const [, pending] of this.pending) {
      pending.reject(error);
    }
    this.pending.clear();
  }
}
