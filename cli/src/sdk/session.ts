/**
 * Session — the primary interface for interacting with the Opal agent.
 *
 * Created via `createSession()`, a Session owns the full lifecycle:
 * transport → RPC connection → typed client → domain operations.
 *
 * @example
 * ```ts
 * import { createSession } from "./sdk/index.js";
 *
 * const session = await createSession({ workingDir: "." });
 *
 * for await (const event of session.prompt("List all files")) {
 *   if (event.type === "messageDelta") process.stdout.write(event.delta);
 * }
 *
 * session.close();
 * ```
 */

import type { Transport } from "./transport/transport.js";
import { StdioTransport } from "./transport/stdio.js";
import { RpcConnection } from "./rpc/connection.js";
import type { RpcObserver } from "./rpc/connection.js";
import { OpalClient } from "./client.js";
import { AgentStream } from "./stream.js";
import type {
  SessionStartParams,
  SessionStartResult,
  AgentStateResult,
  SessionHistoryResult,
  ModelsListResult,
  ModelSetResult,
  OpalConfigGetResult,
  OpalConfigSetParams,
  OpalConfigSetResult,
  OpalVersionResult,
  SettingsGetResult,
  SettingsSaveResult,
  AuthStatusResult,
  AuthLoginResult,
  AuthPollResult,
  AgentEvent,
} from "./protocol.js";

// ── Options ──────────────────────────────────────────────────────────

export interface SessionOptions {
  /** Working directory for agent file operations. Default: process.cwd() */
  workingDir?: string;
  /** Resume an existing session by ID. */
  sessionId?: string;
  // TODO: this kinda bothers me
  /** Persist this session to disk. Default: true when not specified. */
  persist?: boolean;
  /** System prompt override. */
  systemPrompt?: string;
  /** Model selection — string ID shorthand or full spec. */
  model?: string | { id: string; provider?: string; thinkingLevel?: string };
  // TODO: default distribution just shouldn't have these.
  // I don't think I'll ever use any of these toggles.
  /** Feature toggles. */
  features?: Partial<{
    skills: boolean;
    subAgents: boolean;
    mcp: boolean;
    debug: boolean;
  }>;
  // TODO: this bothers me too?
  /** MCP server configurations. */
  mcpServers?: Record<string, unknown>[];

  /** Callbacks for server-initiated interactions and diagnostics. */
  callbacks?: {
    onConfirm?: (request: {
      sessionId: string;
      title: string;
      message: string;
      actions: string[];
    }) => Promise<string>;
    onAskUser?: (request: { question: string; choices?: string[] }) => Promise<string>;
    onRpcMessage?: (entry: {
      id: number;
      direction: "outgoing" | "incoming";
      timestamp: number;
      raw: unknown;
      method?: string;
      kind: string;
    }) => void;
    onStderr?: (data: string) => void;
  };

  /** Auto-confirm all tool executions (for non-interactive SDK use). */
  autoConfirm?: boolean;

  /** Server process configuration. */
  server?: {
    path?: string;
    args?: string[];
    cwd?: string;
  };

  /** Erlang distribution config for remote debugging. */
  distribution?: { name: string; cookie?: string };

  /** Echo raw stderr from the server process to the host stderr. */
  verbose?: boolean;
}

// ── Session ──────────────────────────────────────────────────────────

export class Session {
  /** Unique session identifier. */
  readonly id: string;
  /** Filesystem path to session data. */
  readonly dir: string;
  /** Discovered context files (AGENTS.md, etc). */
  readonly contextFiles: readonly string[];
  /** Available skill names. */
  readonly skills: readonly string[];
  /** Connected MCP server names. */
  readonly mcpServers: readonly string[];
  /** Auth status from session startup. */
  readonly auth: SessionStartResult["auth"];
  /** Erlang distribution node name if active (e.g. "opal_123@hostname"). */
  readonly distributionNode: string | null;

  readonly #client: OpalClient;
  readonly #transport: Transport;
  readonly #rpc: RpcConnection;
  #activeStream: AgentStream | null = null;

  /** @internal Use {@link createSession} instead. */
  private constructor(
    client: OpalClient,
    transport: Transport,
    rpc: RpcConnection,
    result: SessionStartResult,
    distributionNode?: string | null,
  ) {
    this.#client = client;
    this.#transport = transport;
    this.#rpc = rpc;

    this.id = result.sessionId;
    this.dir = result.sessionDir;
    this.contextFiles = result.contextFiles;
    this.skills = result.availableSkills;
    this.mcpServers = result.mcpServers;
    this.auth = result.auth;
    this.distributionNode = distributionNode ?? null;
  }

  // ── Prompting ──────────────────────────────────────────────────

  /**
   * Send a message to the agent. Starts a new run if idle, queues if busy.
   *
   * This is the low-level primitive — events flow through global `onEvent`
   * listeners. Use {@link prompt} for a stream-based convenience wrapper.
   *
   * @returns `queued: true` if the agent was busy (message steered),
   *          `queued: false` if a new run was started.
   */
  async send(text: string): Promise<{ queued: boolean }> {
    const result = await this.#client.request("agent/prompt", {
      sessionId: this.id,
      text,
    });
    return { queued: result.queued };
  }

  /**
   * Send a prompt and stream back events.
   *
   * Convenience wrapper around {@link send} — the returned
   * {@link AgentStream} is an `AsyncIterable<AgentEvent>`.
   * The event subscription is automatically cleaned up when the iterator
   * completes, or when the consumer breaks out of a `for await` loop.
   */
  prompt(text: string): AgentStream {
    const stream = new AgentStream(() => this.abort());

    // Subscribe to events, routing to this stream.
    const sub = this.#client.onEvent((event) => {
      stream.push(event);
    });

    // Fire the request; errors flow into the stream.
    this.send(text).catch((err: unknown) =>
      stream.throw(err instanceof Error ? err : new Error(String(err))),
    );

    // Track active stream for cleanup.
    this.#activeStream = stream;

    // Wrap the async iterator so the event subscription is disposed when
    // the stream finishes — whether by natural completion, `break`, or
    // `return` inside a `for await` loop.
    const origIterator = stream[Symbol.asyncIterator].bind(stream);
    // eslint-disable-next-line @typescript-eslint/no-this-alias -- intentional capture for cleanup closure
    const session = this;
    stream[Symbol.asyncIterator] = function () {
      const iter = origIterator();
      const origReturn = iter.return?.bind(iter);
      return {
        next: iter.next.bind(iter),
        async return(value?: unknown) {
          sub.dispose();
          if (session.#activeStream === stream) session.#activeStream = null;
          return origReturn ? origReturn(value) : { done: true as const, value: undefined };
        },
        throw: iter.throw?.bind(iter),
        [Symbol.asyncIterator]() {
          return this;
        },
      } as AsyncIterator<AgentEvent>;
    };

    return stream;
  }

  /** Abort the current agent run. */
  async abort(): Promise<void> {
    await this.#client.request("agent/abort", { sessionId: this.id });
  }

  // ── History & State ──────────────────────────────────────────

  /** Get the conversation history. */
  async history(): Promise<SessionHistoryResult> {
    return this.#client.request("session/history", { sessionId: this.id });
  }

  /** Compact old messages, keeping `keepRecent` most recent. Default: 10. */
  async compact(keepRecent?: number): Promise<void> {
    await this.#client.request("session/compact", {
      sessionId: this.id,
      keepRecent,
    });
  }

  /** Branch the conversation from a specific message. */
  async branch(entryId: string): Promise<void> {
    await this.#client.request("session/branch", {
      sessionId: this.id,
      entryId,
    });
  }

  /** Get the current agent state. */
  async state(): Promise<AgentStateResult> {
    return this.#client.request("agent/state", { sessionId: this.id });
  }

  // ── Models ───────────────────────────────────────────────────

  /** List available models. */
  async models(): Promise<ModelsListResult> {
    return this.#client.request("models/list", {});
  }

  /** Switch the model for this session. */
  async setModel(
    model: string | { id: string; provider?: string; thinkingLevel?: string },
  ): Promise<ModelSetResult> {
    const spec = typeof model === "string" ? { id: model } : model;
    return this.#client.request("model/set", {
      sessionId: this.id,
      modelId: spec.id,
      ...(spec.thinkingLevel ? { thinkingLevel: spec.thinkingLevel } : {}),
    });
  }

  /** Change thinking/reasoning effort level. */
  async setThinking(level: string): Promise<void> {
    await this.#client.request("thinking/set", {
      sessionId: this.id,
      level,
    });
  }

  // ── Configuration (namespaced) ────────────────────────────────

  /** Configuration operations — settings and runtime config. */
  readonly config = {
    /** Read persisted settings. */
    getSettings: async (): Promise<SettingsGetResult> => {
      return this.#client.request("settings/get");
    },
    /** Save persisted settings. */
    saveSettings: async (settings: Record<string, unknown>): Promise<SettingsSaveResult> => {
      return this.#client.request("settings/save", { settings });
    },
    /** Get runtime config for this session. */
    getRuntime: async (): Promise<OpalConfigGetResult> => {
      return this.#client.request("opal/config/get", { sessionId: this.id });
    },
    /** Patch runtime config for this session. */
    setRuntime: async (
      patch: Omit<OpalConfigSetParams, "sessionId">,
    ): Promise<OpalConfigSetResult> => {
      return this.#client.request("opal/config/set", {
        sessionId: this.id,
        ...patch,
      });
    },
  };

  // ── Auth (namespaced) ─────────────────────────────────────────

  /** Authentication operations — login, poll, and API-key management. */
  readonly auth_ = {
    /** Check current auth status. */
    status: async (): Promise<AuthStatusResult> => {
      return this.#client.request("auth/status");
    },
    /** Start a device-code login flow. */
    login: async (): Promise<AuthLoginResult> => {
      return this.#client.request("auth/login");
    },
    /** Poll for device-code login completion. */
    poll: async (deviceCode: string, interval: number): Promise<AuthPollResult> => {
      return this.#client.request("auth/poll", { deviceCode, interval });
    },
  };

  // ── Events ────────────────────────────────────────────────────

  /**
   * Subscribe to all agent events emitted by the server.
   *
   * Unlike `prompt()` which scopes events to a single agent run,
   * this provides a session-wide subscription suitable for hooks
   * and global event processing.
   *
   * @returns A disposable handle — call `.dispose()` to unsubscribe.
   */
  onEvent(handler: (event: AgentEvent) => void): { dispose: () => void } {
    return this.#client.onEvent(handler);
  }

  // ── Lifecycle ─────────────────────────────────────────────────

  /** Liveness check. Rejects if the server doesn't respond in time. */
  async ping(timeoutMs?: number): Promise<void> {
    await this.#client.ping(timeoutMs);
  }

  /** Get server version info. */
  async version(): Promise<OpalVersionResult> {
    return this.#client.request("opal/version");
  }

  /** Close the session and terminate the server process. */
  close(): void {
    this.#client.close();
    this.#rpc.close();
    this.#transport.close();
  }

  /** Enables `using session = await createSession()` cleanup. */
  [Symbol.dispose](): void {
    this.close();
  }
}

// ── Factory ──────────────────────────────────────────────────────────

/**
 * Create a connected session, ready to receive prompts.
 *
 * Handles the full bootstrap sequence: transport → RPC → client → session/start.
 *
 * @example
 * ```ts
 * const session = await createSession({ workingDir: "." });
 * const stream = session.prompt("Hello!");
 * for await (const ev of stream) { ... }
 * session.close();
 * ```
 */
export async function createSession(opts: SessionOptions = {}): Promise<Session> {
  // 1. Build transport
  const transport = new StdioTransport({
    serverPath: opts.server?.path,
    args: opts.server?.args,
    cwd: opts.server?.cwd,
    onStderr: (data: string) => {
      if (opts.verbose) process.stderr.write(data);
      opts.callbacks?.onStderr?.(data);
    },
  });

  // 2. Build RPC connection with optional observer
  const observer: RpcObserver | undefined = opts.callbacks?.onRpcMessage
    ? {
        onOutgoing: (msg: unknown) =>
          opts.callbacks!.onRpcMessage!({
            id: 0,
            direction: "outgoing",
            timestamp: Date.now(),
            raw: msg,
            method: (msg as Record<string, unknown>).method as string | undefined,
            kind: "request",
          }),
        onIncoming: (msg: unknown) => {
          const m = msg as Record<string, unknown>;
          const hasMethod = typeof m.method === "string";
          const hasId = "id" in m;
          opts.callbacks!.onRpcMessage!({
            id: 0,
            direction: "incoming",
            timestamp: Date.now(),
            raw: msg,
            method: hasMethod ? (m.method as string) : undefined,
            kind: hasMethod ? (hasId ? "request" : "notification") : m.error ? "error" : "response",
          });
        },
      }
    : undefined;

  const rpc = new RpcConnection(transport, observer);

  // 3. Build client and register server→client callback handlers
  const client = new OpalClient(rpc);
  const { callbacks } = opts;

  client.addServerMethod("client/ask_user", async (params) => {
    if (callbacks?.onAskUser) {
      const answer = await callbacks.onAskUser({
        question: params.question,
        choices: params.choices,
      });
      return { answer };
    }
    throw new Error("No ask_user handler registered");
  });

  client.addServerMethod("client/confirm", async (params) => {
    if (opts.autoConfirm) {
      return { action: "allow" };
    }
    if (callbacks?.onConfirm) {
      const action = await callbacks.onConfirm(params);
      return { action };
    }
    return { action: "allow" };
  });

  // 4. Start the session
  const startParams: SessionStartParams = {
    workingDir: opts.workingDir,
    systemPrompt: opts.systemPrompt,
    ...(opts.persist !== undefined ? { session: opts.persist } : {}),
    ...(opts.sessionId ? { sessionId: opts.sessionId } : {}),
    ...(opts.features
      ? {
          features: {
            skills: false,
            subAgents: false,
            mcp: false,
            debug: false,
            ...opts.features,
          },
        }
      : {}),
    ...(opts.mcpServers ? { mcpServers: opts.mcpServers } : {}),
    ...(opts.model
      ? {
          model:
            typeof opts.model === "string"
              ? { id: opts.model, provider: "copilot" }
              : {
                  id: opts.model.id,
                  provider: opts.model.provider ?? "copilot",
                  ...(opts.model.thinkingLevel ? { thinkingLevel: opts.model.thinkingLevel } : {}),
                },
        }
      : {}),
  };

  const result = await client.request("session/start", startParams, 30_000);

  // Start Erlang distribution if requested (for remote debugging via `--expose`).
  // Non-fatal: if distribution fails (e.g. epmd not running), the session still works.
  let distributionNode: string | null = null;
  if (opts.distribution) {
    try {
      const configResult = await client.request(
        "opal/config/set",
        {
          sessionId: result.sessionId,
          distribution: opts.distribution,
        },
        10_000,
      );
      distributionNode = configResult.distribution?.node ?? null;
    } catch {
      // Distribution unavailable — continue without it.
    }
  }

  // Session constructor is private but accessible within this module.
  return new (Session as unknown as new (
    client: OpalClient,
    transport: Transport,
    rpc: RpcConnection,
    result: SessionStartResult,
    distributionNode?: string | null,
  ) => Session)(client, transport, rpc, result, distributionNode);
}
