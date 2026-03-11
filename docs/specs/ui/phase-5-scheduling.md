# Phase 5 — Scheduling

> Scheduled conversations: start new or wake existing sessions on a cron-like schedule. Only runs while the app is open.

## Goal

Add a scheduling feature that lets users configure timed triggers for Opal conversations. A schedule can either start a **new conversation** with a predefined prompt or **wake an existing session** by sending it a follow-up prompt. Schedules only fire while the app is open — there is no background daemon or system service.

## Prerequisites

- Phase 4 complete (full feature parity with CLI)

## Scope

### In Scope

- Schedule management UI (create, edit, delete, enable/disable)
- Two schedule types: "new conversation" and "wake existing"
- Cron-like recurrence (every N minutes/hours, daily at time, weekly, custom cron)
- One-shot schedules (fire once at a specific time)
- Schedule execution engine (in-app, only when app is open)
- Execution history log
- Notification when a schedule fires (system notification + in-app)
- Schedule list in sidebar or dedicated section
- Missed schedule handling (fire on next app open, or skip)

### Out of Scope

- Background execution when app is closed (explicit non-goal)
- System-level cron/launchd/Task Scheduler integration
- Remote/cloud schedule execution
- Complex multi-step workflows or chaining

## Design

### Schedule Types

#### 1. New Conversation

Creates a fresh session with a predefined prompt. Useful for recurring tasks:

- "Run the test suite and report failures" — every morning at 9am
- "Check for dependency updates" — weekly on Monday
- "Summarize git log since yesterday" — daily at 6pm

```typescript
interface NewConversationSchedule {
  type: "new";
  name: string;
  prompt: string;                    // the initial prompt to send
  workingDir: string;                // project directory
  model?: string;                    // optional model override
  autoConfirm?: boolean;             // auto-approve tool executions
  systemPrompt?: string;             // optional custom system prompt
}
```

#### 2. Wake Existing Session

Sends a follow-up prompt to an existing saved session, resuming it. Useful for:

- "Any new CI failures since last check?" — sent to a long-running CI monitor session
- "Update the changelog" — sent to a project maintenance session
- "Check deployment status" — sent to a DevOps assistant session

```typescript
interface WakeSessionSchedule {
  type: "wake";
  name: string;
  sessionId: string;                 // existing session to resume
  prompt: string;                    // the follow-up prompt to send
}
```

### Recurrence Model

Schedules support several recurrence patterns:

```typescript
type Recurrence =
  | { type: "once"; at: Date }                           // fire once
  | { type: "interval"; every: number; unit: "minutes" | "hours" }  // repeating
  | { type: "daily"; at: string }                        // "09:00" local time
  | { type: "weekly"; day: DayOfWeek; at: string }       // "monday" at "09:00"
  | { type: "cron"; expression: string };                // full cron expression
```

For the interval type, the timer starts when the app opens (or when the schedule is created). It does not try to align to wall-clock time.

### Schedule Data Model

```typescript
interface Schedule {
  id: string;
  name: string;
  enabled: boolean;
  target: NewConversationSchedule | WakeSessionSchedule;
  recurrence: Recurrence;
  createdAt: string;
  lastRunAt: string | null;
  nextRunAt: string | null;
  missedBehavior: "run_on_open" | "skip";
  executionHistory: ScheduleExecution[];
}

interface ScheduleExecution {
  scheduledAt: string;
  executedAt: string;
  sessionId: string;
  status: "completed" | "error";
  error?: string;
}
```

## Architecture

### Execution Engine

The schedule engine runs entirely in the Electron main process as a simple timer-based system:

```typescript
// electron/scheduler.ts
class Scheduler {
  private schedules: Map<string, Schedule> = new Map();
  private timers: Map<string, NodeJS.Timeout> = new Map();

  start(): void {
    // Load schedules from disk
    this.loadSchedules();

    // Check for missed schedules
    this.handleMissedSchedules();

    // Set up timers for all enabled schedules
    for (const schedule of this.schedules.values()) {
      if (schedule.enabled) {
        this.armSchedule(schedule);
      }
    }
  }

  private armSchedule(schedule: Schedule): void {
    const nextRun = this.computeNextRun(schedule);
    if (!nextRun) return;

    const delay = nextRun.getTime() - Date.now();
    if (delay <= 0) {
      this.execute(schedule);
      return;
    }

    const timer = setTimeout(() => {
      this.execute(schedule);
      // Re-arm for recurring schedules
      if (schedule.recurrence.type !== "once") {
        this.armSchedule(schedule);
      }
    }, delay);

    this.timers.set(schedule.id, timer);
  }

  private async execute(schedule: Schedule): Promise<void> {
    const execution: ScheduleExecution = {
      scheduledAt: schedule.nextRunAt!,
      executedAt: new Date().toISOString(),
      sessionId: "",
      status: "completed",
    };

    try {
      if (schedule.target.type === "new") {
        // Create new session and send prompt
        const session = await createSession({
          workingDir: schedule.target.workingDir,
          model: schedule.target.model,
          systemPrompt: schedule.target.systemPrompt,
        });
        execution.sessionId = session.id;

        // Send the prompt and iterate the stream to completion
        const result = await session.prompt(schedule.target.prompt).finalMessage();

        // Notify the user
        this.notify(schedule, execution);
      } else {
        // Resume existing session and send prompt
        const session = await createSession({
          workingDir: this.getSessionWorkingDir(schedule.target.sessionId),
          sessionId: schedule.target.sessionId,
        });
        execution.sessionId = schedule.target.sessionId;

        const result = await session.prompt(schedule.target.prompt).finalMessage();

        this.notify(schedule, execution);
      }
    } catch (error) {
      execution.status = "error";
      execution.error = String(error);
    }

    schedule.executionHistory.push(execution);
    schedule.lastRunAt = execution.executedAt;
    this.saveSchedules();
  }

  stop(): void {
    for (const timer of this.timers.values()) {
      clearTimeout(timer);
    }
    this.timers.clear();
  }
}
```

### Persistence

Schedules are stored in `~/.opal/schedules.json`:

```json
{
  "schedules": [
    {
      "id": "sched_abc123",
      "name": "Morning test run",
      "enabled": true,
      "target": {
        "type": "new",
        "prompt": "Run the full test suite. Report any failures with file and line number.",
        "workingDir": "/Users/sergio/Projects/myapp",
        "autoConfirm": true
      },
      "recurrence": {
        "type": "daily",
        "at": "09:00"
      },
      "missedBehavior": "run_on_open",
      "lastRunAt": "2026-03-10T09:00:12Z",
      "executionHistory": []
    }
  ]
}
```

### Missed Schedule Handling

When the app opens, the scheduler checks for schedules that should have fired while the app was closed:

- **`run_on_open`**: Execute immediately on app launch (default). Only the most recent missed occurrence fires — not every missed one.
- **`skip`**: Do nothing. The schedule resumes on its next natural occurrence.

## UI

### Schedule List

A new section in the sidebar or a dedicated tab:

```
┌─ Schedules ───────────────────────────────────┐
│                                                │
│ [+ New Schedule]                               │
│                                                │
│ ☑ Morning test run                             │
│   Daily at 9:00 AM · ~/Projects/myapp          │
│   Last run: Today at 9:00 AM ✓                 │
│   Next: Tomorrow at 9:00 AM                    │
│                                                │
│ ☑ Dependency check                             │
│   Weekly on Monday at 10:00 AM                  │
│   Last run: Monday ✓                           │
│   Next: Next Monday at 10:00 AM                │
│                                                │
│ ☐ Deploy status (disabled)                     │
│   Every 30 minutes · session: "DevOps"         │
│   Last run: Never                              │
│                                                │
└────────────────────────────────────────────────┘
```

### Schedule Editor

```
┌─ New Schedule ────────────────────────────────┐
│                                                │
│ Name: [Morning test run                     ]  │
│                                                │
│ Type: (● New conversation  ○ Wake session)     │
│                                                │
│ Prompt:                                        │
│ ┌──────────────────────────────────────────┐   │
│ │ Run the full test suite. Report any      │   │
│ │ failures with file and line number.      │   │
│ └──────────────────────────────────────────┘   │
│                                                │
│ Working directory: [/Users/sergio/myapp  ] [📁]│
│                                                │
│ Model: [claude-sonnet-4              ▾]        │
│ ☑ Auto-confirm tool executions                 │
│                                                │
│ ─────────────────────────────────────────────  │
│                                                │
│ Recurrence:                                    │
│   ○ Once at: [2026-03-15] [14:00]              │
│   ○ Every [30] [minutes ▾]                     │
│   ● Daily at [09:00]                           │
│   ○ Weekly on [Monday ▾] at [09:00]            │
│   ○ Custom cron: [                          ]  │
│                                                │
│ If missed while app was closed:                │
│   ● Run when app opens                         │
│   ○ Skip until next occurrence                 │
│                                                │
│             [Save]  [Cancel]  [Test Now]        │
└────────────────────────────────────────────────┘
```

For "Wake session" type, replace the working directory / model fields with a session picker:

```
│ Type: (○ New conversation  ● Wake session)     │
│                                                │
│ Session: [CI Monitor — ~/Projects/myapp  ▾]    │
│                                                │
│ Prompt:                                        │
│ ┌──────────────────────────────────────────┐   │
│ │ Any new CI failures since last check?    │   │
│ └──────────────────────────────────────────┘   │
```

### Execution History

Each schedule has a history view showing past executions:

```
┌─ Morning test run — History ──────────────────┐
│                                                │
│ Mar 11, 9:00 AM  ✓ Completed  session: abc123  │
│ Mar 10, 9:00 AM  ✓ Completed  session: def456  │
│ Mar 9, 9:00 AM   ✗ Error: Connection timeout   │
│ Mar 8, 9:00 AM   ○ Skipped (app closed)        │
│ Mar 7, 9:00 AM   ✓ Completed  session: ghi789  │
│                                                │
│ Clicking a session ID opens that conversation  │
└────────────────────────────────────────────────┘
```

### Notifications

When a schedule fires:

1. **System notification** (via Electron's `Notification` API): "Opal: Morning test run completed" — clicking opens the app and focuses the session
2. **In-app indicator**: Badge on the Schedules sidebar section, and the new session appears in the session list

## Component Inventory

| Component | Purpose |
|-----------|---------|
| `ScheduleList` | List of all schedules with status |
| `ScheduleItem` | Single schedule entry with enable/disable toggle |
| `ScheduleEditor` | Create/edit schedule form |
| `RecurrencePicker` | Recurrence pattern selection |
| `SessionPicker` | Dropdown to select an existing session (for "wake" type) |
| `ExecutionHistory` | History of past schedule executions |
| `ScheduleNotification` | In-app notification when a schedule fires |

## Constraints

### App Must Be Open

This is an explicit design constraint. Schedules only fire when the Electron app is running. There is no:

- Background daemon process
- System service (launchd, systemd, Task Scheduler)
- Tray icon mode

If the app is closed, schedules are missed and handled according to their `missedBehavior` setting. This is intentional — it keeps the system simple, predictable, and avoids the complexity of platform-specific background service management.

A future phase could add tray-icon mode (app minimizes to tray, schedules keep firing), but that is explicitly out of scope for Phase 5.

### Resource Management

When a schedule creates a new session, the opal-server process is started (if not already running) and the session runs. If multiple schedules fire concurrently, each gets its own session. The scheduler limits concurrent executions to a configurable maximum (default: 2) to avoid resource exhaustion.

Sessions created by schedules appear in the normal session list and can be interacted with like any other session. They are not special — they're just sessions that were started automatically.

## Acceptance Criteria

1. User can create a "new conversation" schedule with a prompt and working directory
2. User can create a "wake session" schedule targeting an existing session
3. Schedules support: once, interval, daily, weekly, and custom cron recurrence
4. Schedules fire correctly while the app is open
5. Schedules do NOT fire when the app is closed
6. On app open, missed schedules with `run_on_open` fire immediately
7. On app open, missed schedules with `skip` are skipped
8. Schedule executions appear in the history log
9. System notifications fire when a schedule completes
10. Sessions created by schedules appear in the session list
11. Schedules can be enabled/disabled without deletion
12. Schedules can be tested immediately with "Test Now"
13. Concurrent schedule execution is limited to prevent resource exhaustion
14. Schedule data persists across app restarts
