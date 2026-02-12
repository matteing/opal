import { useState, useEffect, useCallback, useRef } from "react";
import type {
  AgentEvent,
  AgentStateResult,
  TokenUsage,
  ConfirmRequest,
} from "../sdk/protocol.js";
import { Session, type SessionOptions } from "../sdk/session.js";

// --- State types ---

export interface Message {
  role: "user" | "assistant";
  content: string;
}

export interface Task {
  tool: string;
  callId: string;
  args: Record<string, unknown>;
  meta: string;
  status: "running" | "done" | "error";
  result?: { ok: boolean; output?: string; error?: string };
  subTasks?: Task[];
}

export interface Skill {
  name: string;
  description: string;
  status: "loaded";
}

export interface Context {
  files: string[];
  status: "discovered";
}

export type TimelineEntry =
  | { kind: "message"; message: Message }
  | { kind: "tool"; task: Task }
  | { kind: "skill"; skill: Skill }
  | { kind: "context"; context: Context };

export interface OpalState {
  timeline: TimelineEntry[];
  thinking: string | null;
  isRunning: boolean;
  confirmation: ConfirmRequest | null;
  modelPicker: { models: { id: string; name: string }[]; current: string } | null;
  currentModel: string | null;
  tokenUsage: TokenUsage | null;
  sessionReady: boolean;
  error: string | null;
  workingDir: string;
  nodeName: string;
  lastDeltaAt: number;
}

export interface OpalActions {
  submitPrompt: (text: string) => void;
  submitSteer: (text: string) => void;
  abort: () => void;
  compact: () => void;
  resolveConfirmation: (action: string) => void;
  runCommand: (input: string) => void;
  selectModel: (modelId: string) => void;
  dismissModelPicker: () => void;
}

// --- Hook ---

export function useOpal(opts: SessionOptions): [OpalState, OpalActions] {
  const [state, setState] = useState<OpalState>({
    timeline: [],
    thinking: null,
    isRunning: false,
    confirmation: null,
    modelPicker: null,
    currentModel: null,
    tokenUsage: null,
    sessionReady: false,
    error: null,
    workingDir: opts.workingDir ?? process.cwd(),
    nodeName: "",
    lastDeltaAt: 0,
  });

  const sessionRef = useRef<Session | null>(null);
  const confirmResolverRef = useRef<((action: string) => void) | null>(null);

  useEffect(() => {
    let mounted = true;

    Session.start({
      session: true,
      ...opts,
      onConfirm: async (req) => {
        if (!mounted) return "deny";
        return new Promise<string>((resolve) => {
          confirmResolverRef.current = resolve;
          setState((s) => ({ ...s, confirmation: req }));
        });
      },
    })
      .then((session) => {
        if (!mounted) {
          session.close();
          return;
        }
        sessionRef.current = session;
        setState((s) => ({ ...s, sessionReady: true, nodeName: session.nodeName }));
        session.getState().then((res) => {
          setState((s) => ({ ...s, currentModel: res.model.id }));
        }).catch(() => {});
      })
      .catch((err) => {
        if (mounted) {
          setState((s) => ({
            ...s,
            error: err instanceof Error ? err.message : String(err),
          }));
        }
      });

    return () => {
      mounted = false;
      sessionRef.current?.close();
    };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const processEvents = useCallback(async (iter: AsyncIterable<AgentEvent>) => {
    for await (const event of iter) {
      if (event.type === "agentEnd" || event.type === "agentAbort") {
        process.stderr.write("\x07");
      }
      setState((s) => applyEvent(s, event));
    }
  }, []);

  const submitPrompt = useCallback(
    (text: string) => {
      const session = sessionRef.current;
      if (!session) return;

      setState((s) => ({
        ...s,
        isRunning: true,
        timeline: [...s.timeline, { kind: "message", message: { role: "user", content: text } }],
      }));

      processEvents(session.prompt(text));
    },
    [processEvents],
  );

  const submitSteer = useCallback(
    (text: string) => {
      const session = sessionRef.current;
      if (!session) return;

      setState((s) => ({
        ...s,
        timeline: [...s.timeline, { kind: "message", message: { role: "user", content: `[steer] ${text}` } }],
      }));

      session.steer(text);
    },
    [],
  );

  const abort = useCallback(() => {
    sessionRef.current?.abort();
  }, []);

  const compact = useCallback(() => {
    sessionRef.current?.compact();
  }, []);

  const resolveConfirmation = useCallback((action: string) => {
    confirmResolverRef.current?.(action);
    confirmResolverRef.current = null;
    setState((s) => ({ ...s, confirmation: null }));
  }, []);

  const addSystemMessage = useCallback((content: string) => {
    setState((s) => ({
      ...s,
      timeline: [...s.timeline, { kind: "message", message: { role: "assistant", content } }],
    }));
  }, []);

  const runCommand = useCallback(
    (input: string) => {
      const session = sessionRef.current;
      if (!session) return;

      const parts = input.trim().slice(1).split(/\s+/);
      const cmd = parts[0]?.toLowerCase();
      const arg = parts.slice(1).join(" ");

      switch (cmd) {
        case "models": {
          // Open interactive model picker
          Promise.all([session.listModels(), session.getState()]).then(([modelsRes, stateRes]) => {
            const models = modelsRes.models.map((m: any) => ({ id: m.id as string, name: m.name as string }));
            setState((s) => ({ ...s, modelPicker: { models, current: stateRes.model.id } }));
          }).catch((e) => addSystemMessage(`Error: ${e.message}`));
          break;
        }
        case "model": {
          if (!arg) {
            session.getState().then((res) => {
              addSystemMessage(`Current model: **${res.model.id}** (${res.model.provider})`);
            }).catch((e) => addSystemMessage(`Error: ${e.message}`));
          } else {
            session.setModel(arg).then((res) => {
              addSystemMessage(`Model changed to **${res.model.id}** (${res.model.provider})`);
              setState((s) => ({ ...s, currentModel: res.model.id }));
            }).catch((e) => addSystemMessage(`Error: ${e.message}`));
          }
          break;
        }
        case "compact": {
          compact();
          addSystemMessage("Compacting conversation…");
          break;
        }
        case "help": {
          addSystemMessage(
            "**Commands:**\n" +
            "  `/model`          — show current model\n" +
            "  `/model <id>`     — switch model\n" +
            "  `/models`         — select model interactively\n" +
            "  `/compact`        — compact conversation history\n" +
            "  `/help`           — show this help"
          );
          break;
        }
        default:
          addSystemMessage(`Unknown command: \`/${cmd}\`. Type \`/help\` for available commands.`);
      }
    },
    [compact, addSystemMessage],
  );

  const selectModel = useCallback(
    (modelId: string) => {
      const session = sessionRef.current;
      if (!session) return;
      setState((s) => ({ ...s, modelPicker: null }));
      session.setModel(modelId).then((res) => {
        addSystemMessage(`Model changed to **${res.model.id}** (${res.model.provider})`);
        setState((s) => ({ ...s, currentModel: res.model.id }));
      }).catch((e) => addSystemMessage(`Error: ${e.message}`));
    },
    [addSystemMessage],
  );

  const dismissModelPicker = useCallback(() => {
    setState((s) => ({ ...s, modelPicker: null }));
  }, []);

  return [
    state,
    { submitPrompt, submitSteer, abort, compact, resolveConfirmation, runCommand, selectModel, dismissModelPicker },
  ];
}

// --- Event reducer ---

function applyEvent(state: OpalState, event: AgentEvent): OpalState {
  switch (event.type) {
    case "agentStart":
      return { ...state, isRunning: true };

    case "agentEnd":
      return {
        ...state,
        isRunning: false,
        thinking: null,
        tokenUsage: event.usage
          ? {
              promptTokens: event.usage.promptTokens,
              completionTokens: event.usage.completionTokens,
              totalTokens: event.usage.totalTokens,
              contextWindow: event.usage.contextWindow,
              currentContextTokens: event.usage.currentContextTokens,
            }
          : state.tokenUsage,
      };

    case "agentAbort":
      return { ...state, isRunning: false, thinking: null };

    case "messageStart":
      return {
        ...state,
        timeline: [...state.timeline, { kind: "message", message: { role: "assistant", content: "" } }],
      };

    case "messageDelta":
      return {
        ...state,
        timeline: appendMessageDelta(state.timeline, event.delta),
        lastDeltaAt: Date.now(),
      };

    case "thinkingStart":
      return { ...state, thinking: "" };

    case "thinkingDelta":
      return {
        ...state,
        thinking: (state.thinking ?? "") + event.delta,
      };

    case "toolExecutionStart":
      return {
        ...state,
        timeline: [
          ...state.timeline,
          {
            kind: "tool",
            task: {
              tool: event.tool,
              callId: event.callId,
              args: event.args,
              meta: event.meta,
              status: "running",
            },
          },
        ],
      };

    case "toolExecutionEnd": {
      const timeline = state.timeline.map((entry) =>
        entry.kind === "tool" && entry.task.callId === event.callId
          ? {
              ...entry,
              task: {
                ...entry.task,
                status: (event.result.ok ? "done" : "error") as Task["status"],
                result: event.result,
              },
            }
          : entry,
      );
      return { ...state, timeline };
    }

    case "subAgentEvent": {
      const inner = event.inner as Record<string, unknown>;
      const innerType = inner.type as string | undefined;
      const parentCallId = event.parentCallId;

      if (innerType === "tool_execution_start") {
        const subTask: Task = {
          tool: inner.tool as string,
          callId: inner.callId as string,
          args: (inner.args as Record<string, unknown>) ?? {},
          meta: (inner.meta as string) ?? "",
          status: "running",
        };
        const timeline = state.timeline.map((entry) =>
          entry.kind === "tool" && entry.task.callId === parentCallId
            ? { ...entry, task: { ...entry.task, subTasks: [...(entry.task.subTasks ?? []), subTask] } }
            : entry,
        );
        return { ...state, timeline };
      }

      if (innerType === "tool_execution_end") {
        const timeline = state.timeline.map((entry) => {
          if (entry.kind === "tool" && entry.task.callId === parentCallId) {
            const innerResult = inner.result as { ok: boolean; output?: string; error?: string };
            const subTasks = (entry.task.subTasks ?? []).map((st) =>
              st.callId === (inner.callId as string)
                ? { ...st, status: (innerResult.ok ? "done" : "error") as Task["status"], result: innerResult }
                : st,
            );
            return { ...entry, task: { ...entry.task, subTasks } };
          }
          return entry;
        });
        return { ...state, timeline };
      }

      return state;
    }

    case "turnEnd":
      return state;

    case "error":
      return { ...state, isRunning: false, error: event.reason };

    case "skillLoaded":
      return {
        ...state,
        timeline: [
          ...state.timeline,
          {
            kind: "skill",
            skill: {
              name: event.name,
              description: event.description,
              status: "loaded",
            },
          },
        ],
      };

    case "contextDiscovered":
      return {
        ...state,
        timeline: [
          ...state.timeline,
          {
            kind: "context",
            context: {
              files: event.files,
              status: "discovered",
            },
          },
        ],
      };

    case "usageUpdate":
      return {
        ...state,
        tokenUsage: event.usage
          ? {
              promptTokens: event.usage.promptTokens,
              completionTokens: event.usage.completionTokens,
              totalTokens: event.usage.totalTokens,
              contextWindow: event.usage.contextWindow,
              currentContextTokens: event.usage.currentContextTokens,
            }
          : state.tokenUsage,
      };

    default:
      return state;
  }
}

function appendMessageDelta(timeline: TimelineEntry[], delta: string): TimelineEntry[] {
  // If the last entry is an assistant message, append directly
  if (timeline.length > 0) {
    const last = timeline[timeline.length - 1]!;
    if (last.kind === "message" && last.message.role === "assistant") {
      return [
        ...timeline.slice(0, -1),
        { kind: "message", message: { ...last.message, content: last.message.content + delta } },
      ];
    }
  }
  // Otherwise (tool entry, user message, or empty) — start a new assistant message
  return [...timeline, { kind: "message", message: { role: "assistant", content: delta } }];
}
