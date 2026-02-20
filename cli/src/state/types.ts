/**
 * Shared types used across store slices.
 *
 * All domain types live here so slices can reference them
 * without circular imports.
 *
 * @module
 */

import type { TokenUsage } from "../sdk/protocol.js";

// ── Timeline ──────────────────────────────────────────────────────

/** A user or assistant message. */
export interface Message {
  readonly role: "user" | "assistant";
  readonly content: string;
}

/** A tracked tool invocation. */
export interface ToolCall {
  readonly tool: string;
  readonly callId: string;
  readonly args: Record<string, unknown>;
  readonly meta: string;
  readonly status: "running" | "done" | "error";
  readonly streamOutput: string;
  readonly result?: { ok: boolean; output?: unknown; error?: string };
}

/** A loaded skill. */
export interface Skill {
  readonly name: string;
  readonly description: string;
}

/** Discovered project context. */
export interface ContextInfo {
  readonly files: readonly string[];
}

/** Discriminated union of timeline entry kinds. */
export type TimelineEntry =
  | { readonly kind: "message"; readonly message: Message }
  | { readonly kind: "tool"; readonly tool: ToolCall }
  | { readonly kind: "thinking"; readonly text: string }
  | { readonly kind: "skill"; readonly skill: Skill }
  | { readonly kind: "context"; readonly context: ContextInfo }
  | { readonly kind: "status"; readonly text: string; readonly level: StatusLevel };

/** Severity for inline status entries. */
export type StatusLevel = "info" | "success" | "error";

/** Unified view state for any agent — root or sub-agent. */
export interface AgentView {
  readonly id: string;
  readonly parentCallId: string | null;
  readonly label: string;
  readonly model: string;
  readonly tools: readonly string[];
  readonly entries: readonly TimelineEntry[];
  readonly thinking: string | null;
  readonly statusMessage: string | null;
  readonly isRunning: boolean;
  readonly startedAt: number;
  readonly toolCount: number;
}

// ── Models ────────────────────────────────────────────────────────

/** An available model. */
export interface ModelInfo {
  readonly id: string;
  readonly name: string;
  readonly provider: string;
  readonly supportsThinking: boolean;
  readonly thinkingLevels: readonly string[];
}

/** The active model. */
export interface ActiveModel {
  readonly id: string;
  readonly provider: string;
  readonly thinkingLevel: string;
  readonly displayName: string;
}

// ── Auth ──────────────────────────────────────────────────────────

/** Auth flow status. */
export type AuthStatus =
  | "checking"
  | "needsAuth"
  | "deviceCode"
  | "polling"
  | "authenticated"
  | "error";

// ── Debug ─────────────────────────────────────────────────────────

/** A single RPC log entry. */
export interface RpcLogEntry {
  readonly id: number;
  readonly direction: "outgoing" | "incoming";
  readonly timestamp: number;
  readonly raw: unknown;
  readonly method?: string;
  readonly kind: string;
}

/** A captured stderr line. */
export interface StderrEntry {
  readonly timestamp: number;
  readonly text: string;
}

// ── Session ───────────────────────────────────────────────────────

/** Connection lifecycle status. */
export type SessionStatus = "connecting" | "ready" | "error";

// ── Reexport ──────────────────────────────────────────────────────

export type { TokenUsage };
