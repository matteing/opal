import { useState, useEffect, useCallback, useRef, useMemo } from "react";
import type { AgentEvent, TokenUsage, ConfirmRequest } from "../sdk/protocol.js";
import { Session, type SessionOptions } from "../sdk/session.js";
import { applyEvent, combineDeltas, emptyAgentView } from "../lib/reducers.js";

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

export function useOpal(opts: SessionOptions): [OpalState, OpalActions] {
  const [state, setState] = useState<OpalState>({
    main: emptyAgentView(),
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

// applyAgentEvent, applyEvent, appendMessageDelta, appendThinkingDelta, combineDeltas
// are now imported from lib/reducers.ts
