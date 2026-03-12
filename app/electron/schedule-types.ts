/**
 * Schedule types for the Opal Desktop scheduler.
 *
 * Schedules fire only while the app is open — no background daemon.
 * Persistence is a flat JSON file at ~/.opal/schedules.json.
 */

// ── Schedule target ──────────────────────────────────────────

export interface NewConversationTarget {
  type: "new";
  prompt: string;
  workingDir: string;
  model?: string;
  autoConfirm?: boolean;
}

export interface WakeSessionTarget {
  type: "wake";
  sessionId: string;
  prompt: string;
}

export type ScheduleTarget = NewConversationTarget | WakeSessionTarget;

// ── Recurrence ───────────────────────────────────────────────

export type Recurrence =
  | { type: "once"; at: string }
  | { type: "interval"; every: number; unit: "minutes" | "hours" }
  | { type: "daily"; at: string }
  | { type: "weekly"; day: string; at: string }
  | { type: "cron"; expression: string };

export const DAYS_OF_WEEK = [
  "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
] as const;

// ── Execution history ────────────────────────────────────────

export interface ScheduleExecution {
  scheduledAt: string;
  executedAt: string;
  sessionId: string;
  status: "completed" | "error";
  error?: string;
}

// ── Schedule ─────────────────────────────────────────────────

export interface Schedule {
  id: string;
  name: string;
  enabled: boolean;
  target: ScheduleTarget;
  recurrence: Recurrence;
  createdAt: string;
  lastRunAt: string | null;
  nextRunAt: string | null;
  missedBehavior: "run_on_open" | "skip";
  executionHistory: ScheduleExecution[];
}

/** Wire format for ~/.opal/schedules.json */
export interface ScheduleStore {
  schedules: Schedule[];
}
