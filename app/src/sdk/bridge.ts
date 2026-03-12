/** Typed bridge to the preload-exposed `window.opal` API. */
export interface OpalBridge {
  startSession: (opts: { workingDir?: string }) => Promise<{ sessionId: string; workingDir: string }>;
  prompt: (text: string) => Promise<void>;
  abort: () => Promise<void>;
  steer: (text: string) => Promise<{ queued: boolean }>;
  getState: () => Promise<unknown>;
  onEvent: (cb: (event: AgentEventWire) => void) => () => void;
  onConfirm: (cb: (params: ConfirmParams) => void) => () => void;
  resolveConfirm: (id: string, action: string) => Promise<void>;
  onAskUser: (cb: (params: AskUserParams) => void) => () => void;
  resolveAskUser: (id: string, answer: string) => Promise<void>;
}

export interface AgentEventWire {
  type: string;
  [key: string]: unknown;
}

export interface ConfirmParams {
  id: string;
  tool: string;
  args: Record<string, unknown>;
  message?: string;
}

export interface AskUserParams {
  id: string;
  question: string;
  choices?: string[];
}

declare global {
  interface Window {
    opal: OpalBridge;
  }
}

export const bridge: OpalBridge = window.opal;
