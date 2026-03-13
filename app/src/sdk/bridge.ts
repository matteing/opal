/** Typed bridge to the preload-exposed `window.opal` API. */
export interface OpalBridge {
  // Session lifecycle
  createSession: (opts: { workingDir?: string }) => Promise<SessionEntry>;
  resumeSession: (id: string, opts?: { workingDir?: string }) => Promise<SessionEntry>;
  listSessions: () => Promise<{ sessions: SessionListItem[] }>;
  deleteSession: (id: string) => Promise<void>;
  switchSession: (id: string) => Promise<boolean>;
  getHistory: (id: string) => Promise<{ messages: HistoryMessage[] }>;
  branchSession: (id: string, messageId: string) => Promise<void>;
  openDirectoryPicker: () => Promise<string | null>;

  // Active session actions
  prompt: (text: string) => Promise<void>;
  abort: () => Promise<void>;
  steer: (text: string) => Promise<{ queued: boolean }>;
  compact: () => Promise<void>;

  // Models
  listModels: () => Promise<{ models: ModelInfo[] }>;
  setModel: (id: string, thinkingLevel?: string) => Promise<unknown>;
  setThinking: (level: string) => Promise<unknown>;

  // Auth
  authStatus: () => Promise<{ authenticated: boolean; auth: { status: string; provider: string } }>;
  authLogin: () => Promise<{ userCode: string; verificationUri: string; deviceCode: string; interval: number }>;
  authPoll: (deviceCode: string, interval: number) => Promise<{ authenticated: boolean }>;

  // Settings & Config
  getSettings: () => Promise<{ settings: Record<string, unknown> }>;
  saveSettings: (settings: Record<string, unknown>) => Promise<{ settings: Record<string, unknown> }>;
  getConfig: () => Promise<RuntimeConfig>;
  setConfig: (config: Record<string, unknown>) => Promise<RuntimeConfig>;

  // Version & Plan
  getVersion: () => Promise<{ serverVersion: string; protocolVersion: string }>;
  openPlan: () => Promise<{ opened: boolean; reason?: string }>;

  // Schedules
  listSchedules: () => Promise<ScheduleInfo[]>;
  getSchedule: (id: string) => Promise<ScheduleInfo | null>;
  saveSchedule: (schedule: ScheduleInfo) => Promise<ScheduleInfo>;
  deleteSchedule: (id: string) => Promise<void>;
  toggleSchedule: (id: string, enabled: boolean) => Promise<void>;
  testSchedule: (id: string) => Promise<void>;
  onScheduleExecuted: (cb: (data: { schedule: ScheduleInfo; execution: ScheduleExecutionInfo }) => void) => () => void;

  // Events
  onEvent: (cb: (event: AgentEventWire) => void) => () => void;
  onConfirm: (cb: (params: ConfirmParams) => void) => () => void;
  resolveConfirm: (requestId: string, action: string) => Promise<void>;
  onAskUser: (cb: (params: AskUserParams) => void) => () => void;
  resolveAskUser: (requestId: string, answer: string) => Promise<void>;
}

export interface SessionEntry {
  id: string;
  title: string;
  workingDir: string;
  active: boolean;
}

export interface SessionListItem {
  id: string;
  title?: string;
  modified?: string;
  [key: string]: unknown;
}

export interface HistoryMessage {
  id: string;
  role: string;
  content?: string;
  toolCalls?: { name: string; callId: string; arguments: string }[];
  callId?: string;
  name?: string;
  [key: string]: unknown;
}

export interface ModelInfo {
  id: string;
  name: string;
  provider: string;
  supportsThinking: boolean;
  thinkingLevels?: string[];
}

export interface RuntimeConfig {
  features: { subAgents: boolean; skills: boolean; debug: boolean };
  tools: { all: string[]; enabled: string[]; disabled: string[] };
  distribution: { node: string; cookie: string } | null;
}

export interface AgentEventWire {
  type: string;
  sessionId?: string;
  [key: string]: unknown;
}

export interface ConfirmParams {
  requestId: string;
  sessionId: string;
  tool: string;
  args: Record<string, unknown>;
  message?: string;
}

export interface AskUserParams {
  requestId: string;
  sessionId: string;
  question: string;
  choices?: string[];
}

export interface ScheduleInfo {
  id: string;
  name: string;
  enabled: boolean;
  target: { type: "new"; prompt: string; workingDir: string; model?: string; autoConfirm?: boolean }
        | { type: "wake"; sessionId: string; prompt: string };
  recurrence: { type: string; [key: string]: unknown };
  createdAt: string;
  lastRunAt: string | null;
  nextRunAt: string | null;
  missedBehavior: "run_on_open" | "skip";
  executionHistory: ScheduleExecutionInfo[];
}

export interface ScheduleExecutionInfo {
  scheduledAt: string;
  executedAt: string;
  sessionId: string;
  status: "completed" | "error";
  error?: string;
}

declare global {
  interface Window {
    opal: OpalBridge;
  }
}

/** Lazy accessor — safe if preload hasn't run yet (returns undefined, not a crash). */
export const bridge: OpalBridge = typeof window !== "undefined" && window.opal
  ? window.opal
  : new Proxy({} as OpalBridge, {
      get(_, prop) {
        throw new Error(`window.opal.${String(prop)} called but preload script hasn't loaded. Check electron.vite.config.ts preload output format (must be CJS, not ESM).`);
      },
    });
