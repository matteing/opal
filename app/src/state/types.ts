/**
 * State types for Opal Desktop.
 *
 * This file defines the data shapes used throughout the renderer.
 * Types are intentionally simple (no classes, no methods) so they can
 * be serialized, diffed, and snapshot-tested trivially.
 */

// ── Timeline ─────────────────────────────────────────────────
// A conversation is rendered as a flat list of TimelineEntry values.
// Each variant carries exactly the data its component needs — no more.

export type TimelineEntry =
  | UserEntry
  | AssistantEntry
  | ToolEntry
  | ThinkingEntry
  | ContextEntry
  | SkillEntry
  | StatusEntry
  | ErrorEntry;

export interface UserEntry {
  type: "user";
  text: string;
}

export interface AssistantEntry {
  type: "assistant";
  text: string;
  /** True while the model is still streaming tokens for this message. */
  isStreaming: boolean;
}

export interface ToolEntry {
  type: "tool";
  name: string;
  /** Correlates toolExecutionStart with toolExecutionEnd. */
  callId: string;
  /** JSON-stringified tool arguments (for display). */
  args: string;
  /** Tool output, populated when the tool completes. */
  output: string | null;
  status: "running" | "done" | "error";
}

export interface ThinkingEntry {
  type: "thinking";
  text: string;
}

export interface ContextEntry {
  type: "context";
  /** e.g. "AGENTS.md", ".opal/skills/docs.md" */
  label: string;
}

export interface SkillEntry {
  type: "skill";
  name: string;
}

export interface StatusEntry {
  type: "status";
  message: string;
}

export interface ErrorEntry {
  type: "error";
  message: string;
}

// ── Token usage ──────────────────────────────────────────────

export interface TokenUsage {
  /** Tokens in the current context window (prompt_tokens from last API call). */
  current: number;
  /** Maximum context window size for the active model. */
  contextWindow: number;
}

// ── Dialog requests ──────────────────────────────────────────
// These are pending server→client requests that block the agent until resolved.

export interface ConfirmRequest {
  /** Unique request ID (used to resolve the promise in the main process). */
  id: string;
  tool: string;
  args: Record<string, unknown>;
  message?: string;
}

export interface AskUserRequest {
  /** Unique request ID (used to resolve the promise in the main process). */
  id: string;
  question: string;
  choices?: string[];
}

// ── Per-session view ─────────────────────────────────────────
// Each active session has its own independent view state.
// This is the "screen" the user sees when a session is focused.

export interface SessionView {
  timeline: TimelineEntry[];
  isRunning: boolean;
  /** Accumulated extended-thinking text (cleared on agent start/end). */
  thinkingText: string;
  /** Brief human-readable status from the agent (e.g. "Reading file…"). */
  statusMessage: string;
  tokenUsage: TokenUsage | null;
  currentModel: string | null;
  /** Pending tool-approval dialog, if any. */
  confirmation: ConfirmRequest | null;
  /** Pending agent question dialog, if any. */
  askUser: AskUserRequest | null;
}

// ── Session list ─────────────────────────────────────────────

export interface SessionListEntry {
  id: string;
  title: string;
  workingDir: string;
  createdAt: string;
  /** True if this session is loaded in memory (has a SessionView). */
  active: boolean;
}
