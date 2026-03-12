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

declare global {
  interface Window {
    opal: OpalBridge;
  }
}

export const bridge: OpalBridge = window.opal;
