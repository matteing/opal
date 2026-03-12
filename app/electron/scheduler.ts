/**
 * Schedule execution engine.
 *
 * Runs entirely in the Electron main process. Uses setTimeout-based timers
 * to fire schedules at the right time. Only runs while the app is open —
 * no background daemon, no system services.
 *
 * Persistence: ~/.opal/schedules.json (read on start, written after each change).
 * Concurrency: limits to MAX_CONCURRENT simultaneous executions.
 */

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { Notification } from "electron";
import { createSession } from "@unfinite/opal-sdk";
import type {
  Schedule,
  ScheduleExecution,
  ScheduleStore,
  Recurrence,
} from "./schedule-types.js";

const MAX_CONCURRENT = 2;

type NotifyFn = (schedule: Schedule, execution: ScheduleExecution) => void;

export class Scheduler {
  #schedules = new Map<string, Schedule>();
  #timers = new Map<string, ReturnType<typeof setTimeout>>();
  #running = 0;
  #onExecuted: NotifyFn;

  constructor(onExecuted: NotifyFn) {
    this.#onExecuted = onExecuted;
  }

  // ── Lifecycle ──────────────────────────────────────────────

  /** Load schedules from disk, handle missed ones, arm timers. */
  start(): void {
    this.#load();
    this.#handleMissed();
    for (const schedule of this.#schedules.values()) {
      if (schedule.enabled) this.#arm(schedule);
    }
  }

  /** Cancel all timers. */
  stop(): void {
    for (const timer of this.#timers.values()) clearTimeout(timer);
    this.#timers.clear();
  }

  // ── CRUD ───────────────────────────────────────────────────

  list(): Schedule[] {
    return [...this.#schedules.values()];
  }

  get(id: string): Schedule | undefined {
    return this.#schedules.get(id);
  }

  save(schedule: Schedule): void {
    // Compute next run time
    schedule.nextRunAt = computeNextRun(schedule.recurrence)?.toISOString() ?? null;

    this.#schedules.set(schedule.id, schedule);
    this.#persist();

    // Re-arm timer
    this.#disarm(schedule.id);
    if (schedule.enabled) this.#arm(schedule);
  }

  delete(id: string): void {
    this.#disarm(id);
    this.#schedules.delete(id);
    this.#persist();
  }

  toggle(id: string, enabled: boolean): void {
    const schedule = this.#schedules.get(id);
    if (!schedule) return;
    schedule.enabled = enabled;
    this.#persist();

    this.#disarm(id);
    if (enabled) this.#arm(schedule);
  }

  /** Execute a schedule immediately (Test Now button). */
  async testNow(id: string): Promise<void> {
    const schedule = this.#schedules.get(id);
    if (!schedule) return;
    await this.#execute(schedule);
  }

  // ── Timer management ───────────────────────────────────────

  #arm(schedule: Schedule): void {
    const nextRun = computeNextRun(schedule.recurrence);
    if (!nextRun) return;

    schedule.nextRunAt = nextRun.toISOString();

    const delay = nextRun.getTime() - Date.now();
    if (delay <= 0) {
      this.#execute(schedule);
      return;
    }

    const timer = setTimeout(() => {
      this.#execute(schedule).then(() => {
        // Re-arm for recurring schedules
        if (schedule.recurrence.type !== "once" && schedule.enabled) {
          this.#arm(schedule);
        }
      });
    }, delay);

    this.#timers.set(schedule.id, timer);
  }

  #disarm(id: string): void {
    const timer = this.#timers.get(id);
    if (timer) {
      clearTimeout(timer);
      this.#timers.delete(id);
    }
  }

  // ── Execution ──────────────────────────────────────────────

  async #execute(schedule: Schedule): Promise<void> {
    if (this.#running >= MAX_CONCURRENT) return; // skip if at capacity
    this.#running++;

    const execution: ScheduleExecution = {
      scheduledAt: schedule.nextRunAt ?? new Date().toISOString(),
      executedAt: new Date().toISOString(),
      sessionId: "",
      status: "completed",
    };

    try {
      if (schedule.target.type === "new") {
        const session = await createSession({
          workingDir: schedule.target.workingDir,
          model: schedule.target.model,
          autoConfirm: schedule.target.autoConfirm,
        });
        execution.sessionId = session.id;

        await session.prompt(schedule.target.prompt).finalMessage();
      } else {
        const session = await createSession({
          workingDir: ".",
          sessionId: schedule.target.sessionId,
        });
        execution.sessionId = schedule.target.sessionId;

        await session.prompt(schedule.target.prompt).finalMessage();
      }
    } catch (e) {
      execution.status = "error";
      execution.error = String(e);
    }

    this.#running--;

    // Record execution
    schedule.executionHistory = [execution, ...schedule.executionHistory].slice(0, 50);
    schedule.lastRunAt = execution.executedAt;
    this.#persist();

    // Notify
    this.#notify(schedule, execution);
    this.#onExecuted(schedule, execution);
  }

  // ── Missed schedule handling ───────────────────────────────

  #handleMissed(): void {
    const now = Date.now();
    for (const schedule of this.#schedules.values()) {
      if (!schedule.enabled) continue;
      if (schedule.missedBehavior !== "run_on_open") continue;
      if (!schedule.nextRunAt) continue;

      const nextRun = new Date(schedule.nextRunAt).getTime();
      if (nextRun < now) {
        // This schedule should have fired while the app was closed
        this.#execute(schedule);
      }
    }
  }

  // ── Notifications ──────────────────────────────────────────

  #notify(schedule: Schedule, execution: ScheduleExecution): void {
    if (!Notification.isSupported()) return;

    const title = execution.status === "completed"
      ? `✓ ${schedule.name}`
      : `✗ ${schedule.name} failed`;
    const body = execution.status === "completed"
      ? "Schedule completed successfully."
      : execution.error ?? "An error occurred.";

    new Notification({ title, body }).show();
  }

  // ── Persistence ────────────────────────────────────────────

  #load(): void {
    try {
      const data = readFileSync(schedulePath(), "utf-8");
      const store: ScheduleStore = JSON.parse(data);
      for (const s of store.schedules ?? []) {
        this.#schedules.set(s.id, s);
      }
    } catch {
      // No file or invalid JSON — start fresh
    }
  }

  #persist(): void {
    const store: ScheduleStore = {
      schedules: [...this.#schedules.values()],
    };
    const dir = join(homedir(), ".opal");
    mkdirSync(dir, { recursive: true });
    writeFileSync(schedulePath(), JSON.stringify(store, null, 2) + "\n");
  }
}

// ── Next-run computation ─────────────────────────────────────

function schedulePath(): string {
  return join(homedir(), ".opal", "schedules.json");
}

/** Compute the next fire time for a recurrence pattern. */
function computeNextRun(recurrence: Recurrence): Date | null {
  const now = new Date();

  switch (recurrence.type) {
    case "once":
      return new Date(recurrence.at);

    case "interval": {
      const ms = recurrence.every * (recurrence.unit === "hours" ? 3_600_000 : 60_000);
      return new Date(now.getTime() + ms);
    }

    case "daily": {
      const [h, m] = recurrence.at.split(":").map(Number);
      const target = new Date(now);
      target.setHours(h, m, 0, 0);
      if (target <= now) target.setDate(target.getDate() + 1);
      return target;
    }

    case "weekly": {
      const [h, m] = recurrence.at.split(":").map(Number);
      const dayIndex = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        .indexOf(recurrence.day.toLowerCase());
      if (dayIndex < 0) return null;

      const target = new Date(now);
      target.setHours(h, m, 0, 0);
      const currentDay = target.getDay();
      let daysUntil = dayIndex - currentDay;
      if (daysUntil < 0 || (daysUntil === 0 && target <= now)) daysUntil += 7;
      target.setDate(target.getDate() + daysUntil);
      return target;
    }

    case "cron":
      // Full cron parsing is complex — for now, treat as interval of 1 hour
      return new Date(now.getTime() + 3_600_000);
  }
}
