import { OpalClient, type OpalClientOptions } from "./client.js";
import type {
  AgentEvent,
  SessionStartParams,
  SessionStartResult,
  AgentStateResult,
  ModelsListResult,
  ModelSetResult,
  SettingsGetResult,
  SettingsSaveResult,
  ConfirmRequest,
  InputRequest,
} from "./protocol.js";

// --- Event callback types ---

type EventMap = {
  agentStart: [];
  agentEnd: [usage?: { promptTokens: number; completionTokens: number; totalTokens: number; contextWindow: number }];
  agentAbort: [];
  messageStart: [];
  messageDelta: [delta: string];
  thinkingStart: [];
  thinkingDelta: [delta: string];
  toolExecutionStart: [tool: string, callId: string, args: Record<string, unknown>, meta: string];
  toolExecutionEnd: [tool: string, callId: string, result: { ok: boolean; output?: string; error?: string }];
  subAgentEvent: [parentCallId: string, subSessionId: string, inner: Record<string, unknown>];
  turnEnd: [message: string];
  usageUpdate: [usage: { promptTokens: number; completionTokens: number; totalTokens: number; contextWindow: number }];
  statusUpdate: [message: string];
  error: [reason: string];
  contextDiscovered: [files: string[]];
  skillLoaded: [name: string, description: string];
};

type EventName = keyof EventMap;

// --- Session options ---

export interface SessionOptions extends SessionStartParams {
  /** Handler for confirmation requests. If not set, uses autoConfirm. */
  onConfirm?: (req: ConfirmRequest) => Promise<string>;
  /** Handler for input requests. */
  onInput?: (req: InputRequest) => Promise<string>;
  /** Auto-confirm all tool executions (for non-interactive SDK use). */
  autoConfirm?: boolean;
  /** Pipe server stderr to process.stderr for debugging. */
  verbose?: boolean;
}

// --- Session ---

export class Session {
  readonly sessionId: string;
  readonly contextFiles: string[];
  readonly availableSkills: string[];
  readonly mcpServers: string[];
  readonly nodeName: string;
  private client: OpalClient;
  private listeners = new Map<EventName, Set<(...args: unknown[]) => void>>();

  private constructor(
    client: OpalClient,
    result: SessionStartResult,
  ) {
    this.client = client;
    this.sessionId = result.sessionId;
    this.contextFiles = result.contextFiles;
    this.availableSkills = result.availableSkills;
    this.mcpServers = result.mcpServers;
    this.nodeName = result.nodeName;

    client.onEvent((event) => this.dispatchEvent(event));
  }

  /**
   * Start a new session.
   */
  static async start(
    opts: SessionOptions = {},
    clientOpts?: OpalClientOptions,
  ): Promise<Session> {
    const { onConfirm, onInput, autoConfirm, verbose, ...startParams } = opts;

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
        throw new Error(`Unknown server request: ${method}`);
      },
    });

    if (verbose) {
      client.on("stderr", (data: string) => process.stderr.write(data));
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
        await new Promise<void>((r) => { resolve = r; });
      }
    } finally {
      this.client.removeListener("agent/event", handler);
    }
  }

  /**
   * Steer the agent mid-run.
   */
  async steer(text: string): Promise<void> {
    await this.client.request("agent/steer", {
      sessionId: this.sessionId,
      text,
    });
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
   * Register a typed event callback.
   */
  on<E extends EventName>(event: E, handler: (...args: EventMap[E]) => void): void {
    if (!this.listeners.has(event)) {
      this.listeners.set(event, new Set());
    }
    this.listeners.get(event)!.add(handler as (...args: unknown[]) => void);
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
      }
    }
  }
}
