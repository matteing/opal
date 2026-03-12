import {
  createSession,
  type Session,
  type AgentEvent,
  type SessionOptions,
} from "@unfinite/opal-sdk";

export interface SessionEntry {
  id: string;
  title: string;
  workingDir: string;
  active: boolean;
}

type SendFn = (channel: string, ...args: unknown[]) => void;
type ConfirmResolver = (result: { action: string }) => void;
type AskUserResolver = (result: string) => void;

/**
 * Manages multiple Opal SDK sessions in the main process.
 * Routes events, confirm/ask-user dialogs to the renderer keyed by session ID.
 */
export class SessionManager {
  #sessions = new Map<string, Session>();
  #activeId: string | null = null;
  #send: SendFn;
  #confirmResolvers = new Map<string, ConfirmResolver>();
  #askUserResolvers = new Map<string, AskUserResolver>();

  constructor(send: SendFn) {
    this.#send = send;
  }

  get activeId(): string | null {
    return this.#activeId;
  }

  get active(): Session | null {
    return this.#activeId ? this.#sessions.get(this.#activeId) ?? null : null;
  }

  /** Create a brand new session. */
  async create(opts: { workingDir?: string }): Promise<SessionEntry> {
    const workingDir = opts.workingDir ?? process.cwd();
    const session = await this.#startSession({ workingDir });
    this.#activeId = session.id;
    return {
      id: session.id,
      title: "New conversation",
      workingDir,
      active: true,
    };
  }

  /** Resume a saved session from disk. */
  async resume(
    sessionId: string,
    opts: { workingDir?: string },
  ): Promise<SessionEntry> {
    // If already loaded, just switch to it
    if (this.#sessions.has(sessionId)) {
      this.#activeId = sessionId;
      return {
        id: sessionId,
        title: "",
        workingDir: opts.workingDir ?? "",
        active: true,
      };
    }

    const workingDir = opts.workingDir ?? process.cwd();
    const session = await this.#startSession({ workingDir, sessionId });
    this.#activeId = session.id;
    return {
      id: session.id,
      title: "",
      workingDir,
      active: true,
    };
  }

  /** Switch the active session (must already be loaded). */
  switchTo(sessionId: string): boolean {
    if (!this.#sessions.has(sessionId)) return false;
    this.#activeId = sessionId;
    return true;
  }

  /** Get history for a session. */
  async getHistory(sessionId: string): Promise<unknown> {
    const session = this.#sessions.get(sessionId);
    if (!session) throw new Error(`session ${sessionId} not loaded`);
    return session.history();
  }

  /** Branch a session at a specific message. */
  async branch(sessionId: string, messageId: string): Promise<void> {
    const session = this.#sessions.get(sessionId);
    if (!session) throw new Error(`session ${sessionId} not loaded`);
    await session.branch(messageId);
  }

  /** List saved sessions using any available session's RPC connection. */
  async list(): Promise<unknown> {
    // Use any active session to call session/list
    const anySession = this.#sessions.values().next().value;
    if (!anySession) {
      // Need a temporary session to query. Create one, list, don't keep it.
      const tmp = await createSession({ workingDir: process.cwd() });
      try {
        const result = await tmp.listSessions();
        return result;
      } finally {
        tmp.close();
      }
    }
    return anySession.listSessions();
  }

  /** Delete a saved session. */
  async delete(sessionId: string): Promise<void> {
    const session = this.#sessions.get(sessionId);
    if (session) {
      session.close();
      this.#sessions.delete(sessionId);
    }
    // Also delete from disk via any available session
    const anySession = this.#sessions.values().next().value;
    if (anySession) {
      await anySession.deleteSession(sessionId);
    }
    // If we deleted the active session, clear it
    if (this.#activeId === sessionId) {
      this.#activeId = this.#sessions.keys().next().value ?? null;
    }
  }

  /** Send a prompt to the active session. */
  async prompt(text: string): Promise<void> {
    const session = this.active;
    if (!session) throw new Error("no active session");
    for await (const _event of session.prompt(text)) {
      // events forwarded by onEvent handler
    }
  }

  /** Steer the active session. */
  async steer(text: string): Promise<unknown> {
    const session = this.active;
    if (!session) throw new Error("no active session");
    return session.steer(text);
  }

  /** Abort the active session. */
  async abort(): Promise<void> {
    const session = this.active;
    if (!session) return;
    await session.abort();
  }

  /** Resolve a pending confirm dialog. */
  resolveConfirm(requestId: string, action: string): void {
    const resolver = this.#confirmResolvers.get(requestId);
    if (resolver) {
      resolver({ action });
      this.#confirmResolvers.delete(requestId);
    }
  }

  /** Resolve a pending ask-user dialog. */
  resolveAskUser(requestId: string, answer: string): void {
    const resolver = this.#askUserResolvers.get(requestId);
    if (resolver) {
      resolver(answer);
      this.#askUserResolvers.delete(requestId);
    }
  }

  /** Close all sessions on shutdown. */
  closeAll(): void {
    for (const session of this.#sessions.values()) {
      session.close();
    }
    this.#sessions.clear();
    this.#activeId = null;
  }

  // ── Private ────────────────────────────────────────────────

  async #startSession(opts: Partial<SessionOptions>): Promise<Session> {
    let confirmCounter = 0;
    let askCounter = 0;

    const session = await createSession({
      ...opts,
      callbacks: {
        onConfirm: async (params) => {
          const requestId = `confirm-${++confirmCounter}`;
          this.#send("opal:agent:confirm", {
            ...params,
            requestId,
            sessionId: session.id,
          });
          return new Promise<{ action: string }>((resolve) => {
            this.#confirmResolvers.set(requestId, resolve);
          });
        },
        onAskUser: async (params) => {
          const requestId = `ask-${++askCounter}`;
          this.#send("opal:agent:ask-user", {
            ...params,
            requestId,
            sessionId: session.id,
          });
          return new Promise<string>((resolve) => {
            this.#askUserResolvers.set(requestId, resolve);
          });
        },
      },
    });

    // Route events tagged with the session ID
    session.onEvent((event: AgentEvent) => {
      this.#send("opal:agent:event", {
        ...event,
        sessionId: session.id,
      });
    });

    this.#sessions.set(session.id, session);
    return session;
  }
}
