/**
 * Session — the primary interface for interacting with the Opal agent.
 *
 * Created via `createSession()`, a Session owns the full lifecycle:
 * transport → RPC connection → typed client → domain operations.
 *
 * @example
 * ```ts
 * import { createSession } from "@unfinite/opal-sdk";
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
import { AgentStream } from "./stream.js";
import type { SessionStartResult, AgentStateResult, SessionHistoryResult, ModelsListResult, ModelSetResult, OpalConfigGetResult, OpalConfigSetParams, OpalConfigSetResult, OpalVersionResult, SettingsGetResult, SettingsSaveResult, AuthStatusResult, AuthLoginResult, AuthPollResult, AgentEvent } from "./protocol.js";
export interface SessionOptions {
    /** Working directory for agent file operations. Default: process.cwd() */
    workingDir?: string;
    /** Resume an existing session by ID. */
    sessionId?: string;
    /** Persist this session to disk. Default: true when not specified. */
    persist?: boolean;
    /** System prompt override. */
    systemPrompt?: string;
    /** Model selection — string ID shorthand or full spec. */
    model?: string | {
        id: string;
        provider?: string;
        thinkingLevel?: string;
    };
    /** Feature toggles. */
    features?: Partial<{
        skills: boolean;
        subAgents: boolean;
        debug: boolean;
    }>;
    /** Callbacks for server-initiated interactions and diagnostics. */
    callbacks?: {
        onConfirm?: (request: {
            sessionId: string;
            title: string;
            message: string;
            actions: string[];
        }) => Promise<string>;
        onAskUser?: (request: {
            question: string;
            choices?: string[];
        }) => Promise<string>;
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
    distribution?: {
        name: string;
        cookie?: string;
    };
    /** Echo raw stderr from the server process to the host stderr. */
    verbose?: boolean;
}
export declare class Session {
    #private;
    /** Unique session identifier. */
    readonly id: string;
    /** Filesystem path to session data. */
    readonly dir: string;
    /** Discovered context files (AGENTS.md, etc). */
    readonly contextFiles: readonly string[];
    /** Available skill names. */
    readonly skills: readonly string[];
    /** Auth status from session startup. */
    readonly auth: SessionStartResult["auth"];
    /** Erlang distribution node name if active (e.g. "opal_123@hostname"). */
    readonly distributionNode: string | null;
    /** @internal Use {@link createSession} instead. */
    private constructor();
    /**
     * Send a message to the agent. Starts a new run if idle, queues if busy.
     *
     * This is the low-level primitive — events flow through global `onEvent`
     * listeners. Use {@link prompt} for a stream-based convenience wrapper.
     *
     * @returns `queued: true` if the agent was busy (message steered),
     *          `queued: false` if a new run was started.
     */
    send(text: string): Promise<{
        queued: boolean;
    }>;
    /**
     * Send a prompt and stream back events.
     *
     * Convenience wrapper around {@link send} — the returned
     * {@link AgentStream} is an `AsyncIterable<AgentEvent>`.
     * The event subscription is automatically cleaned up when the iterator
     * completes, or when the consumer breaks out of a `for await` loop.
     */
    prompt(text: string): AgentStream;
    /** Abort the current agent run. */
    abort(): Promise<void>;
    /** Get the conversation history. */
    history(): Promise<SessionHistoryResult>;
    /** Compact old messages, keeping `keepRecent` most recent. Default: 10. */
    compact(keepRecent?: number): Promise<void>;
    /** Branch the conversation from a specific message. */
    branch(entryId: string): Promise<void>;
    /** Get the current agent state. */
    state(): Promise<AgentStateResult>;
    /** List available models. */
    models(): Promise<ModelsListResult>;
    /** Switch the model for this session. */
    setModel(model: string | {
        id: string;
        provider?: string;
        thinkingLevel?: string;
    }): Promise<ModelSetResult>;
    /** Change thinking/reasoning effort level. */
    setThinking(level: string): Promise<void>;
    /** Configuration operations — settings and runtime config. */
    readonly config: {
        /** Read persisted settings. */
        getSettings: () => Promise<SettingsGetResult>;
        /** Save persisted settings. */
        saveSettings: (settings: Record<string, unknown>) => Promise<SettingsSaveResult>;
        /** Get runtime config for this session. */
        getRuntime: () => Promise<OpalConfigGetResult>;
        /** Patch runtime config for this session. */
        setRuntime: (patch: Omit<OpalConfigSetParams, "sessionId">) => Promise<OpalConfigSetResult>;
    };
    /** Authentication operations — login, poll, and API-key management. */
    readonly auth_: {
        /** Check current auth status. */
        status: () => Promise<AuthStatusResult>;
        /** Start a device-code login flow. */
        login: () => Promise<AuthLoginResult>;
        /** Poll for device-code login completion. */
        poll: (deviceCode: string, interval: number) => Promise<AuthPollResult>;
    };
    /**
     * Subscribe to all agent events emitted by the server.
     *
     * Unlike `prompt()` which scopes events to a single agent run,
     * this provides a session-wide subscription suitable for hooks
     * and global event processing.
     *
     * @returns A disposable handle — call `.dispose()` to unsubscribe.
     */
    onEvent(handler: (event: AgentEvent) => void): {
        dispose: () => void;
    };
    /** Liveness check. Rejects if the server doesn't respond in time. */
    ping(timeoutMs?: number): Promise<void>;
    /** Get server version info. */
    version(): Promise<OpalVersionResult>;
    /** Close the session and terminate the server process. */
    close(): void;
    /** Enables `using session = await createSession()` cleanup. */
    [Symbol.dispose](): void;
}
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
export declare function createSession(opts?: SessionOptions): Promise<Session>;
//# sourceMappingURL=session.d.ts.map