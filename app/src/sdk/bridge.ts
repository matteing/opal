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
