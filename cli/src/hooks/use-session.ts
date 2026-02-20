/**
 * useSession — React lifecycle hook for an Opal agent session.
 *
 * Creates a {@link Session} on mount, tears it down on unmount, and exposes
 * a lightweight event subscription. All state management is the consumer's
 * responsibility — this hook owns the connection, nothing else.
 *
 * @example
 * ```tsx
 * function Agent() {
 *   const { session, status, error } = useSession({
 *     workingDir: ".",
 *     onEvent: (event) => dispatch(event),
 *     onAskUser: async (req) => showModal(req),
 *   });
 *
 *   if (status === "connecting") return <Text>Starting…</Text>;
 *   if (status === "error") return <Text color="red">{error}</Text>;
 *
 *   return <Prompt onSubmit={(text) => session!.prompt(text)} />;
 * }
 * ```
 *
 * @module
 */

import { useState, useEffect, useRef } from "react";
import { createSession } from "../sdk/session.js";
import type { Session, SessionOptions } from "../sdk/session.js";
import type { AgentEvent } from "../sdk/protocol.js";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/** Connection lifecycle status. */
export type SessionStatus = "connecting" | "ready" | "error";

/** Stable result shape returned by `useSession`. */
export interface UseSessionResult {
  /** The live session reference. `null` until `status` is `"ready"`. */
  session: Session | null;
  /** Connection lifecycle status. */
  status: SessionStatus;
  /** Error message when `status` is `"error"`, otherwise `null`. */
  error: string | null;
}

/** Options accepted by the `useSession` hook. */
export interface UseSessionOptions extends SessionOptions {
  /**
   * Called for every agent event emitted by the server.
   * Wire this to your own reducer, state machine, or logger.
   */
  onEvent?: (event: AgentEvent) => void;

  /**
   * Called when the session is successfully established.
   * Useful for one-time setup like restoring history.
   */
  onReady?: (session: Session) => void;

  /**
   * Called when session creation fails or the connection drops.
   */
  onError?: (error: Error) => void;

  /**
   * Handle an ask_user request from the server (the ask_user tool).
   * Return the user's chosen answer.
   * Safe to use component state — forwarded through a ref.
   */
  onAskUser?: (request: { question: string; choices?: string[] }) => Promise<string>;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/** Liveness ping interval when idle (ms). */
const PING_INTERVAL = 15_000;

/** Consecutive ping failures before flagging an error. */
const PING_FAIL_THRESHOLD = 2;

// ---------------------------------------------------------------------------
// Hook
// ---------------------------------------------------------------------------

/**
 * Manage the lifecycle of an Opal agent session.
 *
 * - **Mount** → creates the session via `createSession()`.
 * - **Ready** → subscribes to agent events, starts liveness pings.
 * - **Unmount** → disposes event subscription, stops pings, closes session.
 *
 * The returned `session` is the raw SDK2 {@link Session} — call
 * `session.prompt()`, `session.steer()`, `session.abort()`, etc. directly.
 */
export function useSession(opts: UseSessionOptions): UseSessionResult {
  const [status, setStatus] = useState<SessionStatus>("connecting");
  const [error, setError] = useState<string | null>(null);
  const sessionRef = useRef<Session | null>(null);

  // Keep callbacks in refs so the effect doesn't re-run when they change,
  // and so server callbacks always see the latest closure.
  const onEventRef = useRef(opts.onEvent);
  const onReadyRef = useRef(opts.onReady);
  const onErrorRef = useRef(opts.onError);
  const onAskUserRef = useRef(opts.onAskUser);
  onEventRef.current = opts.onEvent;
  onReadyRef.current = opts.onReady;
  onErrorRef.current = opts.onError;
  onAskUserRef.current = opts.onAskUser;

  // ── Session creation & teardown ─────────────────────────────────

  useEffect(() => {
    let mounted = true;
    let eventSub: { dispose(): void } | null = null;
    let pingTimer: ReturnType<typeof setInterval> | null = null;

    void createSession({
      ...opts,
      callbacks: {
        ...opts.callbacks,
        onAskUser: (req) => {
          const handler = onAskUserRef.current ?? opts.callbacks?.onAskUser;
          if (handler) return handler(req);
          return Promise.reject(new Error("No ask_user handler registered"));
        },
      },
    })
      .then((session: Session) => {
        if (!mounted) {
          session.close();
          return;
        }

        sessionRef.current = session;

        // Subscribe to agent events
        eventSub = session.onEvent((event: AgentEvent) => {
          onEventRef.current?.(event);
        });

        // Periodic liveness pings
        let failCount = 0;
        pingTimer = setInterval(() => {
          session.ping().then(
            () => {
              failCount = 0;
            },
            () => {
              failCount++;
              if (failCount >= PING_FAIL_THRESHOLD && mounted) {
                const err = new Error("Server is unresponsive");
                setError(err.message);
                setStatus("error");
                onErrorRef.current?.(err);
              }
            },
          );
        }, PING_INTERVAL);

        setStatus("ready");
        onReadyRef.current?.(session);
      })
      .catch((err: unknown) => {
        if (!mounted) return;
        const e = err instanceof Error ? err : new Error(String(err));
        setError(e.message);
        setStatus("error");
        onErrorRef.current?.(e);
      });

    return () => {
      mounted = false;
      eventSub?.dispose();
      if (pingTimer !== null) clearInterval(pingTimer);
      sessionRef.current?.close();
      sessionRef.current = null;
    };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  return { session: sessionRef.current, status, error };
}
