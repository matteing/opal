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
  skills: string[];
  mcpServers: string[];
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
  modelPicker: { models: { id: string; name: string; provider?: string; supportsThinking?: boolean; thinkingLevels?: string[] }[]; current: string; currentThinkingLevel?: string } | null;
  currentModel: string | null;
  tokenUsage: TokenUsage | null;
  statusMessage: string | null;
  sessionReady: boolean;
  availableSkills: string[];
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
  selectModel: (modelId: string, thinkingLevel?: string) => void;
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
    statusMessage: null,
    sessionReady: false,
    availableSkills: [],
    error: null,
    workingDir: opts.workingDir ?? process.cwd(),
    nodeName: "",
    lastDeltaAt: 0,
  });

  const sessionRef = useRef<Session | null>(null);
  const confirmResolverRef = useRef<((action: string) => void) | null>(null);
  const pendingEventsRef = useRef<AgentEvent[]>([]);
  const flushTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

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

        // Inject context discovery into timeline from session start response
        const initialTimeline: TimelineEntry[] = [];
        if (session.contextFiles.length > 0 || session.availableSkills.length > 0 || session.mcpServers.length > 0) {
          initialTimeline.push({
            kind: "context",
            context: { files: session.contextFiles, skills: session.availableSkills, mcpServers: session.mcpServers, status: "discovered" },
          });
        }

        setState((s) => ({
          ...s,
          sessionReady: true,
          nodeName: session.nodeName,
          availableSkills: session.availableSkills,
          timeline: [...s.timeline, ...initialTimeline],
        }));
        session.getState().then((res) => {
          const displaySpec = res.model.provider !== "copilot"
            ? `${res.model.provider}:${res.model.id}`
            : res.model.id;
          setState((s) => ({ ...s, currentModel: displaySpec }));
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

  const flushEvents = useCallback(() => {
    flushTimerRef.current = null;
    const batch = pendingEventsRef.current;
    if (batch.length === 0) return;
    pendingEventsRef.current = [];
    setState((s) => {
      // Clone timeline so in-place mutations in appendMessageDelta don't
      // corrupt the previous React state.
      let next: OpalState = { ...s, timeline: [...s.timeline] };
      for (const event of batch) {
        next = applyEvent(next, event);
      }
      return next;
    });
  }, []);

  const processEvents = useCallback(async (iter: AsyncIterable<AgentEvent>) => {
    for await (const event of iter) {
      if (event.type === "agentEnd" || event.type === "agentAbort") {
        process.stderr.write("\x07");
      }
      pendingEventsRef.current.push(event);

      const isTerminal = event.type === "agentEnd" || event.type === "agentAbort" || event.type === "error";
      if (isTerminal) {
        // Flush immediately for terminal events
        if (flushTimerRef.current !== null) {
          clearTimeout(flushTimerRef.current);
        }
        flushEvents();
      } else if (flushTimerRef.current === null) {
        // Schedule a batched flush
        flushTimerRef.current = setTimeout(flushEvents, 32);
      }
    }
  }, [flushEvents]);

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
            const models = modelsRes.models.map((m: any) => ({
              id: m.id as string,
              name: m.name as string,
              provider: m.provider as string | undefined,
              supportsThinking: m.supportsThinking as boolean | undefined,
              thinkingLevels: m.thinkingLevels as string[] | undefined,
            }));
            setState((s) => ({
              ...s,
              modelPicker: {
                models,
                current: stateRes.model.id,
                currentThinkingLevel: stateRes.model.thinkingLevel,
              },
            }));
          }).catch((e) => addSystemMessage(`Error: ${e.message}`));
          break;
        }
        case "model": {
          if (!arg) {
            session.getState().then((res) => {
              const thinking = res.model.thinkingLevel && res.model.thinkingLevel !== "off"
                ? ` thinking=${res.model.thinkingLevel}`
                : "";
              addSystemMessage(`Current model: **${res.model.id}** (${res.model.provider})${thinking}`);
            }).catch((e) => addSystemMessage(`Error: ${e.message}`));
          } else {
            // Normalize provider/model to provider:model for the backend
            const modelSpec = arg.includes("/") ? arg.replace("/", ":") : arg;
            session.setModel(modelSpec).then((res) => {
              const displaySpec = res.model.provider !== "copilot"
                ? `${res.model.provider}:${res.model.id}`
                : res.model.id;
              addSystemMessage(`Model changed to **${displaySpec}** (${res.model.provider})`);
              setState((s) => ({ ...s, currentModel: displaySpec }));
              // Persist choice
              session.saveSettings({ default_model: `${res.model.provider}:${res.model.id}` }).catch(() => {});
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
            "  `/model`                  — show current model\n" +
            "  `/model <provider:id>`    — switch model (e.g. `anthropic:claude-sonnet-4`)\n" +
            "  `/models`                 — select model interactively\n" +
            "  `/compact`                — compact conversation history\n" +
            "  `/help`                   — show this help"
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
    (modelId: string, thinkingLevel?: string) => {
      const session = sessionRef.current;
      if (!session) return;
      setState((s) => ({ ...s, modelPicker: null }));
      session.setModel(modelId, thinkingLevel).then((res) => {
        const displaySpec = res.model.provider !== "copilot"
          ? `${res.model.provider}:${res.model.id}`
          : res.model.id;
        const thinking = res.model.thinkingLevel && res.model.thinkingLevel !== "off"
          ? ` (thinking: ${res.model.thinkingLevel})`
          : "";
        addSystemMessage(`Model changed to **${displaySpec}**${thinking}`);
        setState((s) => ({ ...s, currentModel: displaySpec }));
        // Persist choice
        session.saveSettings({ default_model: `${res.model.provider}:${res.model.id}` }).catch(() => {});
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
        statusMessage: null,
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
      return { ...state, isRunning: false, thinking: null, statusMessage: null };

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
              skills: [],
              mcpServers: [],
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

    case "statusUpdate":
      return { ...state, statusMessage: event.message };

    default:
      return state;
  }
}

function appendMessageDelta(timeline: TimelineEntry[], delta: string): TimelineEntry[] {
  if (timeline.length > 0) {
    const last = timeline[timeline.length - 1]!;
    if (last.kind === "message" && last.message.role === "assistant") {
      // Mutate the last entry in place — safe because applyEvent already
      // created a new state object and this timeline is the working copy
      // within the batch reducer.
      const updated = { kind: "message" as const, message: { ...last.message, content: last.message.content + delta } };
      timeline[timeline.length - 1] = updated;
      return timeline;
    }
  }
  timeline.push({ kind: "message", message: { role: "assistant", content: delta } });
  return timeline;
}
