/**
 * Session slice — connection lifecycle management.
 *
 * Owns the Opal server connection. Creates the session on `connect`,
 * tears it down on `disconnect`, runs liveness pings, and wires
 * events into the timeline and debug slices.
 *
 * @module
 */

import type { StateCreator } from "zustand";
import { createSession } from "../sdk/session.js";
import type { Session, SessionOptions } from "../sdk/session.js";
import type { AgentEvent } from "../sdk/protocol.js";
import type { SessionStatus } from "./types.js";
import type { TimelineSlice } from "./timeline.js";
import type { ModelsSlice } from "./models.js";
import type { AuthSlice } from "./auth.js";
import type { DebugSlice } from "./debug.js";

// ── Slice state + actions ────────────────────────────────────────

export interface SessionSlice {
  session: Session | null;
  sessionStatus: SessionStatus;
  sessionError: string | null;
  sessionId: string;
  sessionDir: string;
  workingDir: string;
  contextFiles: readonly string[];
  availableSkills: readonly string[];

  /** Create a session and wire up events. */
  connect: (opts: SessionOptions) => void;
  /** Close the session and clean up. */
  disconnect: () => void;
  /** Send a message — prompts if idle, steers if running. */
  sendMessage: (text: string) => void;
}

// ── Merged store type for cross-slice access ─────────────────────

type StoreSlices = SessionSlice & TimelineSlice & ModelsSlice & AuthSlice & DebugSlice;

// ── Constants ────────────────────────────────────────────────────

const PING_INTERVAL = 15_000;
const PING_FAIL_THRESHOLD = 2;

// ── Slice creator ────────────────────────────────────────────────

export const createSessionSlice: StateCreator<StoreSlices, [], [], SessionSlice> = (set, get) => {
  let eventSub: { dispose(): void } | null = null;
  let pingTimer: ReturnType<typeof setInterval> | null = null;
  // Batching: coalesce high-frequency events (32ms window)
  let pendingEvents: AgentEvent[] = [];
  let flushTimer: ReturnType<typeof setTimeout> | null = null;

  function flush() {
    flushTimer = null;
    if (pendingEvents.length === 0) return;
    const batch = pendingEvents;
    pendingEvents = [];
    get().applyEvents(batch);
  }

  function pushEvent(event: AgentEvent) {
    pendingEvents.push(event);
    const isTerminal =
      event.type === "agentEnd" || event.type === "agentAbort" || event.type === "error";

    if (isTerminal) {
      if (flushTimer !== null) clearTimeout(flushTimer);
      flush();
    } else if (flushTimer === null) {
      flushTimer = setTimeout(flush, 32);
    }
  }

  function cleanup() {
    eventSub?.dispose();
    eventSub = null;
    if (pingTimer !== null) clearInterval(pingTimer);
    pingTimer = null;
    if (flushTimer !== null) clearTimeout(flushTimer);
    flushTimer = null;
    pendingEvents = [];
  }

  return {
    session: null,
    sessionStatus: "connecting",
    sessionError: null,
    sessionId: "",
    sessionDir: "",
    workingDir: "",
    contextFiles: [],
    availableSkills: [],

    connect: (opts) => {
      set({ sessionStatus: "connecting", sessionError: null, workingDir: opts.workingDir ?? "" });

      void createSession({
        ...opts,
        callbacks: {
          ...opts.callbacks,
          onRpcMessage: (entry) => get().pushRpcMessage(entry),
          onStderr: (data) => get().pushStderr(data),
        },
      })
        .then((session) => {
          set({
            session,
            sessionStatus: "ready",
            sessionId: session.id,
            sessionDir: session.dir,
            contextFiles: session.contextFiles,
            availableSkills: session.skills,
          });

          // Wire events → timeline
          eventSub = session.onEvent((event: AgentEvent) => {
            pushEvent(event);
          });

          // Auth probe
          get().checkAuth(session);

          // Fetch models
          void get().fetchModels(session);

          // Liveness pings
          let failCount = 0;
          pingTimer = setInterval(() => {
            session.ping().then(
              () => {
                failCount = 0;
              },
              () => {
                failCount++;
                if (failCount >= PING_FAIL_THRESHOLD) {
                  set({
                    sessionError: "Server is unresponsive",
                    sessionStatus: "error",
                  });
                }
              },
            );
          }, PING_INTERVAL);
        })
        .catch((err: unknown) => {
          set({
            sessionError: err instanceof Error ? err.message : String(err),
            sessionStatus: "error",
          });
        });
    },

    disconnect: () => {
      const { session } = get();
      cleanup();
      session?.close();
      set({
        session: null,
        sessionStatus: "connecting",
        sessionError: null,
        sessionId: "",
        sessionDir: "",
        workingDir: "",
        contextFiles: [],
        availableSkills: [],
      });
    },

    sendMessage: (text) => {
      const { session } = get();
      if (!session) return;
      // eslint-disable-next-line @typescript-eslint/no-unsafe-call
      void session.send(text);
    },
  };
};
