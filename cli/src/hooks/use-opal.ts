import { useState, useEffect, useCallback, useRef, useMemo } from "react";
import type { AgentEvent, TokenUsage, ConfirmRequest } from "../sdk/protocol.js";
import { Session, type SessionOptions } from "../sdk/session.js";

// --- State types ---

interface ModelEntry {
  id: string;
  name: string;
  provider?: string;
  supportsThinking?: boolean;
  thinkingLevels?: string[];
}

interface OpalRuntimeConfig {
  features: {
    subAgents: boolean;
    skills: boolean;
    mcp: boolean;
    debug: boolean;
  };
  tools: {
    all: string[];
    enabled: string[];
    disabled: string[];
  };
}

function errorMessage(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

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
  result?: { ok: boolean; output?: unknown; error?: string };
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
  | { kind: "context"; context: Context }
  | { kind: "thinking"; text: string };

/** Shared view shape used by both main agent and sub-agents. */
export interface AgentView {
  timeline: TimelineEntry[];
  thinking: string | null;
  statusMessage: string | null;
  isRunning: boolean;
}

export interface SubAgent extends AgentView {
  sessionId: string;
  parentCallId: string;
  label: string;
  model: string;
  tools: string[];
  startedAt: number;
  toolCount: number;
}

export interface AuthProvider {
  id: string;
  name: string;
  method: "device_code" | "api_key";
  envVar?: string;
  ready: boolean;
}

export interface AuthFlow {
  providers: AuthProvider[];
  // Active device-code flow (set after user picks Copilot)
  deviceCode?: { userCode: string; verificationUri: string };
  // Active API key input (set after user picks a key-based provider)
  apiKeyInput?: { providerId: string; providerName: string };
}

export interface OpalState {
  // Main agent view
  main: AgentView;
  // Sub-agents keyed by sub_session_id
  subAgents: Record<string, SubAgent>;
  activeTab: string; // "main" | sub_session_id
  // Session-level state
  confirmation: ConfirmRequest | null;
  askUser: { question: string; choices: string[] } | null;
  modelPicker: {
    models: {
      id: string;
      name: string;
      provider?: string;
      supportsThinking?: boolean;
      thinkingLevels?: string[];
    }[];
    current: string;
    currentThinkingLevel?: string;
  } | null;
  opalMenu: OpalRuntimeConfig | null;
  currentModel: string | null;
  tokenUsage: TokenUsage | null;
  sessionReady: boolean;
  sessionDir: string;
  availableSkills: string[];
  error: string | null;
  authFlow: AuthFlow | null;
  workingDir: string;
  nodeName: string;
  lastDeltaAt: number;
  /** Server stderr lines captured during startup for diagnostics. */
  serverLogs: string[];
}

export interface OpalActions {
  submitPrompt: (text: string) => void;
  submitSteer: (text: string) => void;
  abort: () => void;
  compact: () => void;
  resolveConfirmation: (action: string) => void;
  resolveAskUser: (answer: string) => void;
  runCommand: (input: string) => void;
  selectModel: (modelId: string, thinkingLevel?: string) => void;
  dismissModelPicker: () => void;
  dismissOpalMenu: () => void;
  toggleOpalFeature: (key: "subAgents" | "skills" | "mcp" | "debug", enabled: boolean) => void;
  toggleOpalTool: (name: string, enabled: boolean) => void;
  switchTab: (tabId: string) => void;
  authStartDeviceFlow: () => void;
  authSubmitKey: (providerId: string, apiKey: string) => void;
}

// --- Hook ---

const EMPTY_VIEW: AgentView = {
  timeline: [],
  thinking: null,
  statusMessage: null,
  isRunning: false,
};

export function useOpal(opts: SessionOptions): [OpalState, OpalActions] {
  const [state, setState] = useState<OpalState>({
    main: { ...EMPTY_VIEW },
    subAgents: {},
    activeTab: "main",
    confirmation: null,
    askUser: null,
    modelPicker: null,
    opalMenu: null,
    currentModel: null,
    tokenUsage: null,
    sessionReady: false,
    sessionDir: "",
    availableSkills: [],
    error: null,
    authFlow: null,
    workingDir: opts.workingDir ?? process.cwd(),
    nodeName: "",
    lastDeltaAt: 0,
    serverLogs: [],
  });

  const sessionRef = useRef<Session | null>(null);
  const confirmResolverRef = useRef<((action: string) => void) | null>(null);
  const askUserResolverRef = useRef<((answer: string) => void) | null>(null);
  const pendingEventsRef = useRef<AgentEvent[]>([]);
  const flushTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Periodic liveness check — ping every 15s when idle
  useEffect(() => {
    if (!state.sessionReady || state.main.isRunning) return;
    let failCount = 0;
    const timer = setInterval(() => {
      const session = sessionRef.current;
      if (!session) return;
      session.ping().catch(() => {
        failCount++;
        if (failCount >= 2) {
          setState((s) => ({
            ...s,
            error: "Server is unresponsive",
          }));
        }
      });
    }, 15_000);
    return () => clearInterval(timer);
  }, [state.sessionReady, state.main.isRunning]);

  useEffect(() => {
    let mounted = true;

    Session.start({
      session: true,
      ...opts,
      onStderr: (data: string) => {
        if (!mounted) return;
        // Capture server logs during startup for diagnostics display
        const lines = data
          .split("\n")
          .map((l) => l.trim())
          .filter((l) => l.length > 0);
        if (lines.length > 0) {
          setState((s) => ({
            ...s,
            serverLogs: [...s.serverLogs, ...lines].slice(-20),
          }));
        }
      },
      onConfirm: async (req) => {
        if (!mounted) return "deny";
        return new Promise<string>((resolve) => {
          confirmResolverRef.current = resolve;
          setState((s) => ({ ...s, confirmation: req }));
        });
      },
      onAskUser: async (req) => {
        if (!mounted) return "";
        return new Promise<string>((resolve) => {
          askUserResolverRef.current = resolve;
          setState((s) => ({
            ...s,
            askUser: { question: req.question, choices: req.choices ?? [] },
          }));
        });
      },
    })
      .then((session) => {
        if (!mounted) {
          session.close();
          return;
        }
        sessionRef.current = session;

        // Server-driven auth: check probe result from session/start
        if (session.auth.status === "setup_required") {
          const providers = (session.auth.providers as unknown as AuthProvider[]).filter(
            (p) => !p.ready,
          );
          setState((s) => ({ ...s, authFlow: { providers } }));
          return;
        }

        markSessionReady(session);
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

  // Shared helper to transition from auth → ready
  const markSessionReady = useCallback((session: Session) => {
    const initialTimeline: TimelineEntry[] = [];
    if (
      session.contextFiles.length > 0 ||
      session.availableSkills.length > 0 ||
      session.mcpServers.length > 0
    ) {
      initialTimeline.push({
        kind: "context",
        context: {
          files: session.contextFiles,
          skills: session.availableSkills,
          mcpServers: session.mcpServers,
          status: "discovered",
        },
      });
    }

    setState((s) => ({
      ...s,
      sessionReady: true,
      authFlow: null,
      sessionDir: session.sessionDir,
      nodeName: session.nodeName,
      availableSkills: session.availableSkills,
      main: { ...s.main, timeline: [...s.main.timeline, ...initialTimeline] },
    }));
    session
      .getState()
      .then((res) => {
        const displaySpec =
          res.model.provider !== "copilot" ? `${res.model.provider}:${res.model.id}` : res.model.id;
        setState((s) => ({ ...s, currentModel: displaySpec }));
      })
      .catch(() => {});
  }, []);

  const flushEvents = useCallback(() => {
    flushTimerRef.current = null;
    const batch = pendingEventsRef.current;
    if (batch.length === 0) return;
    pendingEventsRef.current = [];

    // Pre-combine consecutive delta events to reduce allocations
    const combined = combineDeltas(batch);

    setState((s) => {
      let next: OpalState = s;
      for (const event of combined) {
        next = applyEvent(next, event);
      }
      return next;
    });
  }, []);

  const processEvents = useCallback(
    async (iter: AsyncIterable<AgentEvent>) => {
      for await (const event of iter) {
        if (event.type === "agentEnd" || event.type === "agentAbort") {
          process.stderr.write("\x07");
        }
        pendingEventsRef.current.push(event);

        const isTerminal =
          event.type === "agentEnd" || event.type === "agentAbort" || event.type === "error";
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
    },
    [flushEvents],
  );

  const submitPrompt = useCallback(
    (text: string) => {
      const session = sessionRef.current;
      if (!session) return;

      setState((s) => ({
        ...s,
        main: {
          ...s.main,
          isRunning: true,
          timeline: [
            ...s.main.timeline,
            { kind: "message", message: { role: "user", content: text } },
          ],
        },
      }));

      void processEvents(session.prompt(text));
    },
    [processEvents],
  );

  const submitSteer = useCallback((text: string) => {
    const session = sessionRef.current;
    if (!session) return;

    setState((s) => ({
      ...s,
      main: {
        ...s.main,
        timeline: [
          ...s.main.timeline,
          { kind: "message", message: { role: "user", content: `[steer] ${text}` } },
        ],
      },
    }));

    void session.steer(text);
  }, []);

  const abort = useCallback(() => {
    void sessionRef.current?.abort();
  }, []);

  const compact = useCallback(() => {
    void sessionRef.current?.compact();
  }, []);

  const resolveConfirmation = useCallback((action: string) => {
    confirmResolverRef.current?.(action);
    confirmResolverRef.current = null;
    setState((s) => ({ ...s, confirmation: null }));
  }, []);

  const resolveAskUser = useCallback((answer: string) => {
    askUserResolverRef.current?.(answer);
    askUserResolverRef.current = null;
    setState((s) => ({ ...s, askUser: null }));
  }, []);

  const addSystemMessage = useCallback((content: string) => {
    setState((s) => ({
      ...s,
      main: {
        ...s.main,
        timeline: [
          ...s.main.timeline,
          { kind: "message", message: { role: "assistant", content } },
        ],
      },
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
          Promise.all([session.listModels(), session.getState()])
            .then(([modelsRes, stateRes]) => {
              const models = modelsRes.models.map((m) => {
                const entry = m as unknown as ModelEntry;
                return {
                  id: entry.id,
                  name: entry.name,
                  provider: entry.provider,
                  supportsThinking: entry.supportsThinking,
                  thinkingLevels: entry.thinkingLevels,
                };
              });
              setState((s) => ({
                ...s,
                modelPicker: {
                  models,
                  current: stateRes.model.id,
                  currentThinkingLevel: stateRes.model.thinkingLevel,
                },
              }));
            })
            .catch((e: unknown) => addSystemMessage(`Error: ${errorMessage(e)}`));
          break;
        }
        case "model": {
          if (!arg) {
            session
              .getState()
              .then((res) => {
                const thinking =
                  res.model.thinkingLevel && res.model.thinkingLevel !== "off"
                    ? ` thinking=${res.model.thinkingLevel}`
                    : "";
                addSystemMessage(
                  `Current model: **${res.model.id}** (${res.model.provider})${thinking}`,
                );
              })
              .catch((e: unknown) => addSystemMessage(`Error: ${errorMessage(e)}`));
          } else {
            // Normalize provider/model to provider:model for the backend
            const modelSpec = arg.includes("/") ? arg.replace("/", ":") : arg;
            session
              .setModel(modelSpec)
              .then((res) => {
                const displaySpec =
                  res.model.provider !== "copilot"
                    ? `${res.model.provider}:${res.model.id}`
                    : res.model.id;
                addSystemMessage(`Model changed to **${displaySpec}** (${res.model.provider})`);
                setState((s) => ({ ...s, currentModel: displaySpec }));
                // Persist choice
                session
                  .saveSettings({ default_model: `${res.model.provider}:${res.model.id}` })
                  .catch(() => {});
              })
              .catch((e: unknown) => addSystemMessage(`Error: ${errorMessage(e)}`));
          }
          break;
        }
        case "compact": {
          compact();
          addSystemMessage("Compacting conversation…");
          break;
        }
        case "agents": {
          setState((s) => {
            const subs = Object.values(s.subAgents);
            if (subs.length === 0 && s.activeTab === "main") {
              addSystemMessage("No active sub-agents.");
              return s;
            }
            if (!arg) {
              // List active sub-agents
              const lines = subs.map(
                (sub, i) =>
                  `  ${i + 1}. **${sub.label || sub.sessionId.slice(0, 8)}** — ${sub.model} · ${sub.toolCount} tools · ${sub.isRunning ? "running" : "done"}`,
              );
              const viewing =
                s.activeTab !== "main"
                  ? `\nCurrently viewing: **${s.subAgents[s.activeTab]?.label || s.activeTab}**. Use \`/agents main\` to return.`
                  : "";
              addSystemMessage(
                `**Active sub-agents:**\n${lines.join("\n")}${viewing}\n\nUse \`/agents <number>\` to view, \`/agents main\` to return.`,
              );
              return s;
            }
            // Switch to a specific agent
            if (arg === "main") return { ...s, activeTab: "main" };
            const idx = parseInt(arg, 10);
            if (!isNaN(idx) && idx >= 1 && idx <= subs.length) {
              return { ...s, activeTab: subs[idx - 1].sessionId };
            }
            addSystemMessage(
              `Invalid agent: \`${arg}\`. Use a number (1-${subs.length}) or \`main\`.`,
            );
            return s;
          });
          break;
        }
        case "opal": {
          session
            .getOpalConfig()
            .then((cfg) => {
              setState((s) => ({ ...s, opalMenu: cfg }));
            })
            .catch((e: unknown) => addSystemMessage(`Error: ${errorMessage(e)}`));
          break;
        }
        case "help": {
          addSystemMessage(
            "**Commands:**\n" +
              "  `/model`                  — show current model\n" +
              "  `/model <provider:id>`    — switch model (e.g. `anthropic:claude-sonnet-4`)\n" +
              "  `/models`                 — select model interactively\n" +
              "  `/agents`                 — list active sub-agents\n" +
              "  `/agents <n|main>`        — switch view to sub-agent or main\n" +
              "  `/opal`                   — open configuration menu\n" +
              "  `/compact`                — compact conversation history\n" +
              "  `/help`                   — show this help",
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
      session
        .setModel(modelId, thinkingLevel)
        .then((res) => {
          const displaySpec =
            res.model.provider !== "copilot"
              ? `${res.model.provider}:${res.model.id}`
              : res.model.id;
          const thinking =
            res.model.thinkingLevel && res.model.thinkingLevel !== "off"
              ? ` (thinking: ${res.model.thinkingLevel})`
              : "";
          addSystemMessage(`Model changed to **${displaySpec}**${thinking}`);
          setState((s) => ({ ...s, currentModel: displaySpec }));
          // Persist choice
          session
            .saveSettings({ default_model: `${res.model.provider}:${res.model.id}` })
            .catch(() => {});
        })
        .catch((e: unknown) => addSystemMessage(`Error: ${errorMessage(e)}`));
    },
    [addSystemMessage],
  );

  const dismissModelPicker = useCallback(() => {
    setState((s) => ({ ...s, modelPicker: null }));
  }, []);

  const dismissOpalMenu = useCallback(() => {
    setState((s) => ({ ...s, opalMenu: null }));
  }, []);

  const toggleOpalFeature = useCallback(
    (key: "subAgents" | "skills" | "mcp" | "debug", enabled: boolean) => {
      const session = sessionRef.current;
      if (!session) return;

      // Optimistic update
      setState((s) => {
        if (!s.opalMenu) return s;
        return {
          ...s,
          opalMenu: {
            ...s.opalMenu,
            features: { ...s.opalMenu.features, [key]: enabled },
          },
        };
      });

      session
        .getOpalConfig()
        .then((cfg) =>
          session.setOpalConfig({
            features: { ...cfg.features, [key]: enabled },
          }),
        )
        .then((cfg) => setState((s) => ({ ...s, opalMenu: cfg })))
        .catch((e: unknown) => addSystemMessage(`Error: ${errorMessage(e)}`));
    },
    [addSystemMessage],
  );

  const toggleOpalTool = useCallback(
    (name: string, enabled: boolean) => {
      const session = sessionRef.current;
      if (!session) return;

      // Optimistic update
      setState((s) => {
        if (!s.opalMenu) return s;
        const next = new Set(s.opalMenu.tools.enabled);
        if (enabled) next.add(name);
        else next.delete(name);
        const ordered = s.opalMenu.tools.all.filter((t) => next.has(t));
        return {
          ...s,
          opalMenu: {
            ...s.opalMenu,
            tools: {
              ...s.opalMenu.tools,
              enabled: ordered,
              disabled: s.opalMenu.tools.all.filter((t) => !next.has(t)),
            },
          },
        };
      });

      session
        .getOpalConfig()
        .then((cfg) => {
          const next = new Set(cfg.tools.enabled);
          if (enabled) next.add(name);
          else next.delete(name);
          const ordered = cfg.tools.all.filter((t) => next.has(t));
          return session.setOpalConfig({ tools: ordered });
        })
        .then((cfg) => setState((s) => ({ ...s, opalMenu: cfg })))
        .catch((e: unknown) => addSystemMessage(`Error: ${errorMessage(e)}`));
    },
    [addSystemMessage],
  );

  const switchTab = useCallback((tabId: string) => {
    setState((s) => ({ ...s, activeTab: tabId }));
  }, []);

  const authStartDeviceFlow = useCallback(() => {
    const session = sessionRef.current;
    if (!session) return;
    session
      .authLogin()
      .then((flow) => {
        setState((s) => ({
          ...s,
          authFlow: s.authFlow
            ? {
                ...s.authFlow,
                deviceCode: {
                  userCode: flow.userCode,
                  verificationUri: flow.verificationUri,
                },
              }
            : null,
        }));
        // Poll blocks server-side until user authorizes
        return session.authPoll(flow.deviceCode, flow.interval);
      })
      .then(() => {
        markSessionReady(session);
      })
      .catch((e: unknown) => {
        setState((s) => ({ ...s, error: errorMessage(e) }));
      });
  }, [markSessionReady]);

  const authSubmitKey = useCallback(
    (providerId: string, apiKey: string) => {
      const session = sessionRef.current;
      if (!session) return;

      // Empty key = show the input screen for this provider
      if (!apiKey) {
        const provider = state.authFlow?.providers.find((p) => p.id === providerId);
        setState((s) => ({
          ...s,
          error: null,
          authFlow: s.authFlow
            ? {
                ...s.authFlow,
                apiKeyInput: {
                  providerId,
                  providerName: provider?.name ?? providerId,
                },
              }
            : null,
        }));
        return;
      }

      session
        .authSetKey(providerId, apiKey)
        .then(() => {
          markSessionReady(session);
        })
        .catch((e: unknown) => {
          setState((s) => ({ ...s, error: errorMessage(e) }));
        });
    },
    [markSessionReady, state.authFlow],
  );

  const actions = useMemo(
    () => ({
      submitPrompt,
      submitSteer,
      abort,
      compact,
      resolveConfirmation,
      resolveAskUser,
      runCommand,
      selectModel,
      dismissModelPicker,
      dismissOpalMenu,
      toggleOpalFeature,
      toggleOpalTool,
      switchTab,
      authStartDeviceFlow,
      authSubmitKey,
    }),
    [
      submitPrompt,
      submitSteer,
      abort,
      compact,
      resolveConfirmation,
      resolveAskUser,
      runCommand,
      selectModel,
      dismissModelPicker,
      dismissOpalMenu,
      toggleOpalFeature,
      toggleOpalTool,
      switchTab,
      authStartDeviceFlow,
      authSubmitKey,
    ],
  );

  return [state, actions];
}

// --- Event reducer ---

/** Apply an agent-level event to an AgentView. Shared by main and sub-agents. */
function applyAgentEvent(view: AgentView, event: Record<string, unknown>): AgentView {
  const type = event.type as string;
  switch (type) {
    case "agentStart":
    case "agent_start":
      return { ...view, isRunning: true };

    case "agentEnd":
    case "agent_end":
      return { ...view, isRunning: false, thinking: null, statusMessage: null };

    case "agentAbort":
    case "agent_abort":
      return { ...view, isRunning: false, thinking: null, statusMessage: null };

    case "messageStart":
    case "message_start":
      return {
        ...view,
        timeline: view.timeline.concat({
          kind: "message",
          message: { role: "assistant", content: "" },
        }),
      };

    case "messageDelta":
    case "message_delta":
      return {
        ...view,
        timeline: appendMessageDelta(view.timeline, (event.delta as string) ?? ""),
      };

    case "thinkingStart":
    case "thinking_start":
      return {
        ...view,
        thinking: "",
        timeline: view.timeline.concat({ kind: "thinking", text: "" }),
      };

    case "thinkingDelta":
    case "thinking_delta": {
      const delta = (event.delta as string) ?? "";
      return {
        ...view,
        thinking: (view.thinking ?? "") + delta,
        timeline: appendThinkingDelta(view.timeline, delta),
      };
    }

    case "toolExecutionStart":
    case "tool_execution_start":
      return {
        ...view,
        timeline: view.timeline.concat({
          kind: "tool",
          task: {
            tool: (event.tool as string) ?? "",
            callId: ((event.callId ?? event.call_id) as string) ?? "",
            args: (event.args as Record<string, unknown>) ?? {},
            meta: (event.meta as string) ?? "",
            status: "running",
          },
        }),
      };

    case "toolExecutionEnd":
    case "tool_execution_end": {
      const callId = ((event.callId ?? event.call_id) as string) ?? "";
      const result = event.result as { ok: boolean; output?: unknown; error?: string };
      const idx = view.timeline.findIndex((e) => e.kind === "tool" && e.task.callId === callId);
      if (idx >= 0) {
        const entry = view.timeline[idx] as { kind: "tool"; task: Task };
        const updated = view.timeline.slice();
        updated[idx] = {
          kind: "tool",
          task: {
            ...entry.task,
            status: (result.ok ? "done" : "error") as Task["status"],
            result,
          },
        };
        return { ...view, timeline: updated };
      }
      return view;
    }

    case "statusUpdate":
    case "status_update":
      return { ...view, statusMessage: (event.message as string) ?? null };

    default:
      return view;
  }
}

function applyEvent(state: OpalState, event: AgentEvent): OpalState {
  const e = event as unknown as Record<string, unknown>;
  switch (event.type) {
    case "agentStart":
      return { ...state, main: applyAgentEvent(state.main, e) };

    case "agentEnd":
      return {
        ...state,
        main: applyAgentEvent(state.main, e),
        // Clean up completed sub-agents
        subAgents: {},
        activeTab: "main",
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
      return { ...state, main: applyAgentEvent(state.main, e), subAgents: {}, activeTab: "main" };

    case "messageStart":
    case "messageDelta":
    case "thinkingStart":
    case "thinkingDelta":
    case "toolExecutionStart":
    case "statusUpdate":
      return {
        ...state,
        main: applyAgentEvent(state.main, e),
        lastDeltaAt: event.type === "messageDelta" ? Date.now() : state.lastDeltaAt,
      };

    case "toolExecutionEnd":
      return { ...state, main: applyAgentEvent(state.main, e) };

    case "subAgentEvent": {
      const inner = event.inner;
      const innerType = inner.type as string | undefined;
      const subSessionId = event.subSessionId;
      const parentCallId = event.parentCallId;

      // sub_agent_start: create a new SubAgent entry
      if (innerType === "sub_agent_start") {
        const sub: SubAgent = {
          sessionId: subSessionId,
          parentCallId,
          label: (inner.label as string) ?? "",
          model: (inner.model as string) ?? "",
          tools: (inner.tools as string[]) ?? [],
          timeline: [],
          thinking: null,
          statusMessage: null,
          isRunning: true,
          startedAt: Date.now(),
          toolCount: 0,
        };
        return { ...state, subAgents: { ...state.subAgents, [subSessionId]: sub } };
      }

      // Route other inner events to the sub-agent's AgentView
      const existing = state.subAgents[subSessionId];
      if (!existing) return state;

      const updatedView = applyAgentEvent(
        existing,
        inner as { type: string; [k: string]: unknown },
      );

      // Track tool count
      let toolCount = existing.toolCount;
      if (innerType === "tool_execution_start") toolCount++;

      // If agent_end, mark done and auto-revert tab
      const isDone = innerType === "agent_end";
      const updatedSub: SubAgent = { ...existing, ...updatedView, toolCount, isRunning: !isDone };

      let nextSubAgents: Record<string, SubAgent>;
      let nextTab = state.activeTab;
      if (isDone) {
        // Remove the sub-agent and revert tab if needed
        nextSubAgents = { ...state.subAgents };
        delete nextSubAgents[subSessionId];
        if (nextTab === subSessionId) nextTab = "main";
      } else {
        nextSubAgents = { ...state.subAgents, [subSessionId]: updatedSub };
      }

      return { ...state, subAgents: nextSubAgents, activeTab: nextTab };
    }

    case "turnEnd":
      return state;

    case "error":
      return { ...state, main: { ...state.main, isRunning: false }, error: event.reason };

    case "skillLoaded":
      return {
        ...state,
        main: {
          ...state.main,
          timeline: state.main.timeline.concat({
            kind: "skill",
            skill: { name: event.name, description: event.description, status: "loaded" },
          }),
        },
      };

    case "contextDiscovered":
      return {
        ...state,
        main: {
          ...state.main,
          timeline: state.main.timeline.concat({
            kind: "context",
            context: { files: event.files, skills: [], mcpServers: [], status: "discovered" },
          }),
        },
      };

    case "agentRecovered":
      return {
        ...state,
        main: {
          ...state.main,
          isRunning: false,
          timeline: state.main.timeline.concat({
            kind: "message",
            message: {
              role: "assistant",
              content: "⚠ Agent crashed and recovered — conversation history preserved.",
            },
          }),
        },
        error: null,
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
  const last = timeline[timeline.length - 1];
  if (last?.kind === "message" && last.message.role === "assistant") {
    const updated = timeline.slice();
    updated[timeline.length - 1] = {
      kind: "message",
      message: { role: "assistant", content: last.message.content + delta },
    };
    return updated;
  }
  return [...timeline, { kind: "message", message: { role: "assistant", content: delta } }];
}

function appendThinkingDelta(timeline: TimelineEntry[], delta: string): TimelineEntry[] {
  const last = timeline[timeline.length - 1];
  if (last?.kind === "thinking") {
    const updated = timeline.slice();
    updated[timeline.length - 1] = { kind: "thinking", text: last.text + delta };
    return updated;
  }
  return [...timeline, { kind: "thinking", text: delta }];
}

/**
 * Merge consecutive messageDelta / thinkingDelta events into single events
 * so the reducer creates only one intermediate object per batch instead of N.
 */
function combineDeltas(events: AgentEvent[]): AgentEvent[] {
  const out: AgentEvent[] = [];
  for (const ev of events) {
    if (ev.type === "messageDelta" || ev.type === "thinkingDelta") {
      const prev = out[out.length - 1];
      if (prev && prev.type === ev.type) {
        // Safe cast — both types carry a `delta` string
        (prev as { delta?: string }).delta =
          ((prev as { delta?: string }).delta ?? "") + ((ev as { delta?: string }).delta ?? "");
        continue;
      }
    }
    out.push(ev);
  }
  return out;
}
