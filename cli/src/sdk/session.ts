import { OpalClient, type OpalClientOptions, type RpcMessageEntry } from "./client.js";
import type {
  AgentEvent,
  SessionStartParams,
  SessionStartResult,
  SessionHistoryResult,
  AgentStateResult,
  ModelsListResult,
  ModelSetResult,
  OpalConfigGetResult,
  OpalConfigSetParams,
  OpalConfigSetResult,
  SettingsGetResult,
  SettingsSaveResult,
  ConfirmRequest,
  InputRequest,
  ClientAsk_userParams,
  AuthStatusResult,
  AuthLoginResult,
  AuthPollResult,
  AuthSet_keyResult,
} from "./protocol.js";

// --- Event callback types ---

type EventMap = {
  agentStart: [];
  agentEnd: [
    usage?: {
      promptTokens: number;
      completionTokens: number;
      totalTokens: number;
      contextWindow: number;
    },
  ];
  agentAbort: [];
  messageStart: [];
  messageDelta: [delta: string];
  thinkingStart: [];
  thinkingDelta: [delta: string];
  toolExecutionStart: [tool: string, callId: string, args: Record<string, unknown>, meta: string];
  toolExecutionEnd: [
    tool: string,
    callId: string,
    result: { ok: boolean; output?: unknown; error?: string },
  ];
  subAgentEvent: [parentCallId: string, subSessionId: string, inner: Record<string, unknown>];
  turnEnd: [message: string];
  usageUpdate: [
    usage: {
      promptTokens: number;
      completionTokens: number;
      totalTokens: number;
      contextWindow: number;
    },
  ];
  statusUpdate: [message: string];
  messageQueued: [text: string];
  messageApplied: [text: string];
  error: [reason: string];
  contextDiscovered: [files: string[]];
  skillLoaded: [name: string, description: string];
  agentRecovered: [];
};

type EventName = keyof EventMap;

// --- Session options ---

export interface SessionOptions extends SessionStartParams {
  /** Handler for confirmation requests. If not set, uses autoConfirm. */
  onConfirm?: (req: ConfirmRequest) => Promise<string>;
  /** Handler for input requests. */
  onInput?: (req: InputRequest) => Promise<string>;
  /** Handler for ask_user tool requests. */
  onAskUser?: (req: { question: string; choices?: string[] }) => Promise<string>;
  /** Auto-confirm all tool executions (for non-interactive SDK use). */
  autoConfirm?: boolean;
  /** Pipe server stderr to process.stderr for debugging. */
  verbose?: boolean;
  /** Called with server stderr chunks (useful for startup diagnostics). */
  onStderr?: (data: string) => void;
  /** Called with every JSON-RPC message (for debug panel). */
  onRpcMessage?: (entry: RpcMessageEntry) => void;
  /** Start Erlang distribution with this short name. */
  sname?: string;
  /** Erlang distribution cookie (random if omitted). */
  cookie?: string;
}

// --- Session ---

export class Session {
  readonly sessionId: string;
  readonly sessionDir: string;
  readonly contextFiles: string[];
  readonly availableSkills: string[];
  readonly mcpServers: string[];
  readonly nodeName: string;
  readonly auth: SessionStartResult["auth"];
  private client: OpalClient;
  private listeners = new Map<EventName, Set<(...args: unknown[]) => void>>();

  private constructor(client: OpalClient, result: SessionStartResult) {
    this.client = client;
    this.sessionId = result.sessionId;
    this.sessionDir = result.sessionDir;
    this.contextFiles = result.contextFiles;
    this.availableSkills = result.availableSkills;
    this.mcpServers = result.mcpServers;
    this.nodeName = result.nodeName;
    this.auth = result.auth;

    client.onEvent((event) => this.dispatchEvent(event));
  }

  /**
   * Start a new session.
   */
  static async start(opts: SessionOptions = {}, clientOpts?: OpalClientOptions): Promise<Session> {
    const {
      onConfirm,
      onInput,
      onAskUser,
      autoConfirm,
      verbose,
      onStderr,
      onRpcMessage,
      sname: _sname,
      cookie: _cookie,
      ...startParams
    } = opts;

    const client = new OpalClient({
      ...clientOpts,
      onServerRequest: async (method, params) => {
        if (method === "client/confirm") {
          const req = params as unknown as ConfirmRequest;
          if (onConfirm) {
            const action = await onConfirm(req);
            return { action };
          }
          if (autoConfirm) {
            return { action: "allow" };
          }
          return { action: "deny" };
        }
        if (method === "client/input") {
          const req = params as unknown as InputRequest;
          if (onInput) {
            const text = await onInput(req);
            return { text };
          }
          throw new Error("No input handler registered");
        }
        if (method === "client/ask_user") {
          const req = params as unknown as ClientAsk_userParams;
          if (onAskUser) {
            const answer = await onAskUser({ question: req.question, choices: req.choices });
            return { answer };
          }
          throw new Error("No ask_user handler registered");
        }
        throw new Error(`Unknown server request: ${method}`);
      },
    });

    if (verbose) {
      client.on("stderr", (data: string) => process.stderr.write(data));
    }

    if (onStderr) {
      client.on("stderr", onStderr);
    }

    if (onRpcMessage) {
      client.on("rpc:message", onRpcMessage);
    }

    const result = await client.request("session/start", startParams as SessionStartParams);
    return new Session(client, result);
  }

  /**
   * Send a prompt and iterate over streaming events.
   */
  async *prompt(text: string): AsyncIterable<AgentEvent> {
    const events: AgentEvent[] = [];
    let done = false;
    let resolve: (() => void) | null = null;

    const handler = (event: AgentEvent) => {
      events.push(event);
      if (event.type === "agentEnd" || event.type === "agentAbort" || event.type === "error") {
        done = true;
      }
      resolve?.();
    };

    this.client.onEvent(handler);

    await this.client.request("agent/prompt", {
      sessionId: this.sessionId,
      text,
    });

    try {
      while (true) {
        while (events.length > 0) {
          const event = events.shift()!;
          yield event;
          if (event.type === "agentEnd" || event.type === "agentAbort") return;
          if (event.type === "error") return;
        }
        if (done) return;
        await new Promise<void>((r) => {
          resolve = r;
        });
      }
    } finally {
      this.client.removeListener("agent/event", handler);
    }
  }

  /**
   * Send a prompt without consuming the event stream.
   *
   * Use this for queued messages (steers) where events are already being
   * consumed by an earlier `prompt()` call. Returns `{ queued }` indicating
   * whether the message was queued or started immediately.
   */
  async sendPrompt(text: string): Promise<{ queued: boolean }> {
    return (await this.client.request("agent/prompt", {
      sessionId: this.sessionId,
      text,
    })) as { queued: boolean };
  }

  /**
   * Abort the current agent run.
   */
  async abort(): Promise<void> {
    await this.client.request("agent/abort", {
      sessionId: this.sessionId,
    });
  }

  /**
   * Get the current agent state.
   */
  async getState(): Promise<AgentStateResult> {
    return this.client.request("agent/state", {
      sessionId: this.sessionId,
    });
  }

  /**
   * Get the message history for the session (root to current leaf).
   * Used to restore the UI when resuming a session.
   */
  async getHistory(): Promise<SessionHistoryResult> {
    return this.client.request("session/history", {
      sessionId: this.sessionId,
    });
  }

  /**
   * Compact older messages.
   */
  async compact(keepRecent?: number): Promise<void> {
    await this.client.request("session/compact", {
      sessionId: this.sessionId,
      keepRecent,
    });
  }

  /**
   * List available models.
   */
  async listModels(): Promise<ModelsListResult> {
    return this.client.request("models/list", {});
  }

  /**
   * Change the model for this session.
   */
  async setModel(modelId: string, thinkingLevel?: string): Promise<ModelSetResult> {
    return this.client.request("model/set", {
      sessionId: this.sessionId,
      modelId,
      ...(thinkingLevel ? { thinkingLevel } : {}),
    });
  }

  /**
   * Change the reasoning effort level for the current model.
   */
  async setThinkingLevel(level: string): Promise<{ thinkingLevel: string }> {
    return this.client.request("thinking/set", {
      sessionId: this.sessionId,
      level,
    });
  }

  /**
   * Get persistent user settings.
   */
  async getSettings(): Promise<SettingsGetResult> {
    return this.client.request("settings/get", {});
  }

  /**
   * Save persistent user settings (merged with existing).
   */
  async saveSettings(settings: Record<string, unknown>): Promise<SettingsSaveResult> {
    return this.client.request("settings/save", { settings });
  }

  /**
   * Get runtime Opal feature/tool configuration for this session.
   */
  async getOpalConfig(): Promise<OpalConfigGetResult> {
    return this.client.request("opal/config/get", { sessionId: this.sessionId });
  }

  /**
   * Update runtime Opal feature/tool configuration for this session.
   */
  async setOpalConfig(
    params: Omit<OpalConfigSetParams, "sessionId">,
  ): Promise<OpalConfigSetResult> {
    return this.client.request("opal/config/set", {
      sessionId: this.sessionId,
      ...params,
    });
  }

  /**
   * Start or stop Erlang distribution for remote debugging.
   * Returns the distribution state (node + cookie) or null.
   */
  async setDistribution(
    config: { name: string; cookie?: string } | null,
  ): Promise<{ node: string; cookie: string } | null> {
    // distribution field is handled server-side but not in the generated schema
    const result = (await this.client.request("opal/config/set", {
      sessionId: this.sessionId,
      distribution: config,
    } as unknown as OpalConfigSetParams)) as unknown as Record<string, unknown>;
    return (result.distribution as { node: string; cookie: string } | null) ?? null;
  }

  /**
   * Check whether the server has a valid auth token.
   */
  async authStatus(): Promise<AuthStatusResult> {
    return this.client.request("auth/status", {});
  }

  /**
   * Start the device-code OAuth login flow.
   */
  async authLogin(): Promise<AuthLoginResult> {
    return this.client.request("auth/login", {});
  }

  /**
   * Poll for device-code authorization. Blocks until user authorizes or error.
   */
  async authPoll(deviceCode: string, interval: number): Promise<AuthPollResult> {
    return this.client.request("auth/poll", {
      deviceCode,
      interval,
    });
  }

  /**
   * Save an API key for a provider. Takes effect immediately (no restart).
   */
  async authSetKey(provider: string, apiKey: string): Promise<AuthSet_keyResult> {
    return this.client.request("auth/set_key", { provider, apiKey });
  }

  /**
   * Register a typed event callback.
   */
  on<E extends EventName>(event: E, handler: (...args: EventMap[E]) => void): void {
    if (!this.listeners.has(event)) {
      this.listeners.set(event, new Set());
    }
    this.listeners.get(event)!.add(handler as (...args: unknown[]) => void);
  }

  /**
   * Liveness check. Resolves if the server responds within the timeout.
   */
  async ping(timeoutMs?: number): Promise<void> {
    await this.client.ping(timeoutMs);
  }

  /**
   * Close the session and kill the server.
   */
  close(): void {
    this.client.close();
  }

  // --- Private ---

  private dispatchEvent(event: AgentEvent): void {
    const handlers = this.listeners.get(event.type as EventName);
    if (!handlers) return;

    for (const handler of handlers) {
      switch (event.type) {
        case "agentStart":
        case "agentAbort":
        case "messageStart":
        case "thinkingStart":
          handler();
          break;
        case "agentEnd":
          handler(event.usage);
          break;
        case "messageDelta":
        case "thinkingDelta":
          handler(event.delta);
          break;
        case "toolExecutionStart":
          handler(event.tool, event.callId, event.args, event.meta);
          break;
        case "toolExecutionEnd":
          handler(event.tool, event.callId, event.result);
          break;
        case "subAgentEvent":
          handler(event.parentCallId, event.subSessionId, event.inner);
          break;
        case "turnEnd":
          handler(event.message);
          break;
        case "usageUpdate":
          handler(event.usage);
          break;
        case "statusUpdate":
          handler(event.message);
          break;
        case "error":
          handler(event.reason);
          break;
        case "contextDiscovered":
          handler(event.files);
          break;
        case "skillLoaded":
          handler(event.name, event.description);
          break;
        case "agentRecovered":
          handler();
          break;
        case "messageQueued":
          handler(event.text);
          break;
        case "messageApplied":
          handler(event.text);
          break;
      }
    }
  }
}
