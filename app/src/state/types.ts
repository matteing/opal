export type TimelineEntry =
  | { type: "user"; text: string }
  | { type: "assistant"; text: string; isStreaming: boolean }
  | { type: "tool"; name: string; callId: string; args: string; output: string | null; status: "running" | "done" | "error" }
  | { type: "thinking"; text: string }
  | { type: "context"; label: string }
  | { type: "skill"; name: string }
  | { type: "status"; message: string }
  | { type: "error"; message: string };

export interface TokenUsage {
  current: number;
  contextWindow: number;
}

export interface ConfirmRequest {
  id: string;
  tool: string;
  args: Record<string, unknown>;
  message?: string;
}

export interface AskUserRequest {
  id: string;
  question: string;
  choices?: string[];
}
