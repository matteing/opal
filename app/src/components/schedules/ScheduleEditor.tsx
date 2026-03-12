import { useState, useEffect } from "react";
import { bridge, type ScheduleInfo, type SessionListItem } from "../../sdk/bridge.js";

const EMPTY_SCHEDULE: ScheduleInfo = {
  id: "",
  name: "",
  enabled: true,
  target: { type: "new", prompt: "", workingDir: "" },
  recurrence: { type: "daily", at: "09:00" },
  createdAt: "",
  lastRunAt: null,
  nextRunAt: null,
  missedBehavior: "run_on_open",
  executionHistory: [],
};

export function ScheduleEditor({
  initial,
  onClose,
}: {
  initial: ScheduleInfo | null;
  onClose: () => void;
}) {
  const [schedule, setSchedule] = useState<ScheduleInfo>(initial ?? EMPTY_SCHEDULE);
  const [sessions, setSessions] = useState<SessionListItem[]>([]);

  useEffect(() => {
    bridge.listSessions().then((r) => setSessions(r.sessions ?? [])).catch(() => {});
  }, []);

  const update = (patch: Partial<ScheduleInfo>) =>
    setSchedule((s) => ({ ...s, ...patch }));

  const updateTarget = (patch: Record<string, unknown>) =>
    setSchedule((s) => ({ ...s, target: { ...s.target, ...patch } as ScheduleInfo["target"] }));

  const updateRecurrence = (patch: Record<string, unknown>) =>
    setSchedule((s) => ({ ...s, recurrence: { ...s.recurrence, ...patch } }));

  const handleSave = () => {
    bridge.saveSchedule(schedule).then(onClose).catch(() => {});
  };

  const isNew = schedule.target.type === "new";

  const pickDir = async () => {
    const dir = await bridge.openDirectoryPicker();
    if (dir && isNew) updateTarget({ workingDir: dir });
  };

  return (
    <dialog open>
      <h3>{initial ? "Edit Schedule" : "New Schedule"}</h3>

      <label>
        Name
        <input type="text" value={schedule.name} onChange={(e) => update({ name: e.target.value })} placeholder="Morning test run" />
      </label>

      {/* Type selector */}
      <fieldset>
        <legend>Type</legend>
        <label>
          <input type="radio" name="type" checked={isNew} onChange={() => update({ target: { type: "new", prompt: "", workingDir: "" } })} />
          New conversation
        </label>
        <label>
          <input type="radio" name="type" checked={!isNew} onChange={() => update({ target: { type: "wake", sessionId: "", prompt: "" } })} />
          Wake existing session
        </label>
      </fieldset>

      {/* Prompt */}
      <label>
        Prompt
        <textarea value={schedule.target.prompt} onChange={(e) => updateTarget({ prompt: e.target.value })} rows={3} placeholder="Run the full test suite…" />
      </label>

      {/* Type-specific fields */}
      {isNew ? (
        <>
          <label>
            Working directory
            <span data-role="dir-picker">
              <input type="text" value={(schedule.target as { workingDir: string }).workingDir} onChange={(e) => updateTarget({ workingDir: e.target.value })} />
              <button type="button" onClick={pickDir}>📁</button>
            </span>
          </label>
          <label>
            <input type="checkbox" checked={(schedule.target as { autoConfirm?: boolean }).autoConfirm ?? false} onChange={(e) => updateTarget({ autoConfirm: e.target.checked })} />
            Auto-confirm tool executions
          </label>
        </>
      ) : (
        <label>
          Session
          <select value={(schedule.target as { sessionId: string }).sessionId} onChange={(e) => updateTarget({ sessionId: e.target.value })}>
            <option value="">Select a session…</option>
            {sessions.map((s) => (
              <option key={s.id} value={s.id}>{s.title ?? s.id}</option>
            ))}
          </select>
        </label>
      )}

      {/* Recurrence */}
      <fieldset>
        <legend>Recurrence</legend>
        {(["once", "interval", "daily", "weekly"] as const).map((type) => (
          <label key={type}>
            <input type="radio" name="recurrence" checked={schedule.recurrence.type === type} onChange={() => {
              const defaults: Record<string, Record<string, unknown>> = {
                once: { type: "once", at: new Date().toISOString().slice(0, 16) },
                interval: { type: "interval", every: 30, unit: "minutes" },
                daily: { type: "daily", at: "09:00" },
                weekly: { type: "weekly", day: "monday", at: "09:00" },
              };
              update({ recurrence: defaults[type] as ScheduleInfo["recurrence"] });
            }} />
            {type === "once" ? "Once" : type === "interval" ? "Every" : type === "daily" ? "Daily" : "Weekly"}
          </label>
        ))}

        {/* Recurrence-specific inputs */}
        {schedule.recurrence.type === "once" && (
          <input type="datetime-local" value={String(schedule.recurrence.at ?? "").slice(0, 16)} onChange={(e) => updateRecurrence({ at: e.target.value })} />
        )}
        {schedule.recurrence.type === "interval" && (
          <span>
            <input type="number" min={1} value={Number(schedule.recurrence.every ?? 30)} onChange={(e) => updateRecurrence({ every: parseInt(e.target.value) })} style={{ width: "4rem" }} />
            <select value={String(schedule.recurrence.unit ?? "minutes")} onChange={(e) => updateRecurrence({ unit: e.target.value })}>
              <option value="minutes">minutes</option>
              <option value="hours">hours</option>
            </select>
          </span>
        )}
        {(schedule.recurrence.type === "daily" || schedule.recurrence.type === "weekly") && (
          <input type="time" value={String(schedule.recurrence.at ?? "09:00")} onChange={(e) => updateRecurrence({ at: e.target.value })} />
        )}
        {schedule.recurrence.type === "weekly" && (
          <select value={String(schedule.recurrence.day ?? "monday")} onChange={(e) => updateRecurrence({ day: e.target.value })}>
            {["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"].map((d) => (
              <option key={d} value={d}>{d.charAt(0).toUpperCase() + d.slice(1)}</option>
            ))}
          </select>
        )}
      </fieldset>

      {/* Missed behavior */}
      <fieldset>
        <legend>If missed while app was closed</legend>
        <label>
          <input type="radio" name="missed" checked={schedule.missedBehavior === "run_on_open"} onChange={() => update({ missedBehavior: "run_on_open" })} />
          Run when app opens
        </label>
        <label>
          <input type="radio" name="missed" checked={schedule.missedBehavior === "skip"} onChange={() => update({ missedBehavior: "skip" })} />
          Skip until next occurrence
        </label>
      </fieldset>

      <menu>
        <button onClick={handleSave} disabled={!schedule.name || !schedule.target.prompt}>Save</button>
        <button onClick={onClose}>Cancel</button>
      </menu>
    </dialog>
  );
}
