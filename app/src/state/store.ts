import { create } from "zustand";
import { bridge, type AgentEventWire } from "../sdk/bridge.js";
import type {
  TimelineEntry,
  TokenUsage,
  ConfirmRequest,
  AskUserRequest,
} from "./types.js";

export interface AppState {
  // Connection
  sessionReady: boolean;
  workingDir: string;
  error: string | null;

  // Conversation
  timeline: TimelineEntry[];
  isRunning: boolean;
  thinkingText: string;
  statusMessage: string;

  // Token usage
  currentModel: string | null;
  tokenUsage: TokenUsage | null;

  // Dialogs
  confirmation: ConfirmRequest | null;
  askUser: AskUserRequest | null;

  // Actions
  applyEvent: (event: AgentEventWire) => void;
  startSession: (workingDir?: string) => Promise<void>;
  submitPrompt: (text: string) => void;
  submitSteer: (text: string) => void;
  abort: () => void;
  resolveConfirmation: (action: string) => void;
  resolveAskUser: (answer: string) => void;
  setError: (error: string | null) => void;
}

export const useAppStore = create<AppState>((set, get) => ({
  sessionReady: false,
  workingDir: "",
  error: null,
  timeline: [],
  isRunning: false,
  thinkingText: "",
  statusMessage: "",
  currentModel: null,
  tokenUsage: null,
  confirmation: null,
  askUser: null,

  applyEvent: (event: AgentEventWire) => {
    const { type } = event;

    set((s) => {
      switch (type) {
        case "agentStart":
          return { ...s, isRunning: true, statusMessage: "", thinkingText: "" };

        case "messageStart":
          return {
            ...s,
            timeline: [
              ...s.timeline,
              { type: "assistant", text: "", isStreaming: true },
            ],
          };

        case "messageDelta": {
          const delta = (event.delta as string) ?? "";
          const tl = [...s.timeline];
          const last = tl[tl.length - 1];
          if (last?.type === "assistant") {
            tl[tl.length - 1] = { ...last, text: last.text + delta };
          }
          return { ...s, timeline: tl };
        }

        case "thinkingStart":
          return { ...s, thinkingText: "" };

        case "thinkingDelta": {
          const delta = (event.delta as string) ?? "";
          return { ...s, thinkingText: s.thinkingText + delta };
        }

        case "statusUpdate":
          return {
            ...s,
            statusMessage: (event.message as string) ?? "",
          };

        case "toolExecutionStart": {
          const entry: TimelineEntry = {
            type: "tool",
            name: (event.tool as string) ?? "unknown",
            callId: (event.callId as string) ?? "",
            args: typeof event.args === "string"
              ? event.args
              : JSON.stringify(event.args ?? {}),
            output: null,
            status: "running",
          };
          return { ...s, timeline: [...s.timeline, entry] };
        }

        case "toolExecutionEnd": {
          const callId = (event.callId as string) ?? "";
          const tl = s.timeline.map((e) => {
            if (e.type === "tool" && e.callId === callId) {
              return {
                ...e,
                output: typeof event.result === "string"
                  ? event.result
                  : JSON.stringify(event.result ?? ""),
                status: "done" as const,
              };
            }
            return e;
          });
          return { ...s, timeline: tl };
        }

        case "usageUpdate": {
          const usage = event.usage as Record<string, number> | undefined;
          return {
            ...s,
            currentModel: (event.model as string) ?? s.currentModel,
            tokenUsage: usage
              ? {
                  current: usage.currentContextTokens ?? usage.totalTokens ?? 0,
                  contextWindow: usage.contextWindow ?? 128000,
                }
              : s.tokenUsage,
          };
        }

        case "agentEnd": {
          // Finalize any streaming assistant message
          const tl = s.timeline.map((e) =>
            e.type === "assistant" && e.isStreaming
              ? { ...e, isStreaming: false }
              : e,
          );
          return {
            ...s,
            timeline: tl,
            isRunning: false,
            thinkingText: "",
            statusMessage: "",
          };
        }

        case "agentAbort": {
          const tl = s.timeline.map((e) =>
            e.type === "assistant" && e.isStreaming
              ? { ...e, isStreaming: false }
              : e,
          );
          return {
            ...s,
            timeline: [...tl, { type: "status", message: "Cancelled" }],
            isRunning: false,
            thinkingText: "",
            statusMessage: "",
          };
        }

        case "error":
          return {
            ...s,
            error: (event.message as string) ?? "An error occurred",
          };

        case "contextDiscovered": {
          const files = (event.files as string[]) ?? [];
          const entries: TimelineEntry[] = files.map((f) => ({
            type: "context" as const,
            label: f,
          }));
          return { ...s, timeline: [...s.timeline, ...entries] };
        }

        case "skillLoaded":
          return {
            ...s,
            timeline: [
              ...s.timeline,
              { type: "skill", name: (event.name as string) ?? "unknown" },
            ],
          };

        default:
          return s;
      }
    });
  },

  startSession: async (workingDir?: string) => {
    try {
      const result = await bridge.startSession({
        workingDir: workingDir ?? process.cwd?.() ?? ".",
      });
      set({ sessionReady: true, workingDir: result.workingDir });
    } catch (e) {
      set({ error: `Failed to start session: ${e}` });
    }
  },

  submitPrompt: (text: string) => {
    const state = get();
    set({
      timeline: [...state.timeline, { type: "user", text }],
      error: null,
    });
    bridge.prompt(text).catch((e) => {
      set({ error: `Prompt failed: ${e}` });
    });
  },

  submitSteer: (text: string) => {
    bridge.steer(text).catch((e) => {
      set({ error: `Steer failed: ${e}` });
    });
  },

  abort: () => {
    bridge.abort().catch(() => {});
  },

  resolveConfirmation: (action: string) => {
    const state = get();
    if (state.confirmation) {
      bridge.resolveConfirm(state.confirmation.id, action);
      set({ confirmation: null });
    }
  },

  resolveAskUser: (answer: string) => {
    const state = get();
    if (state.askUser) {
      bridge.resolveAskUser(state.askUser.id, answer);
      set({ askUser: null });
    }
  },

  setError: (error: string | null) => set({ error }),
}));
