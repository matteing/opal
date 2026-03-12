import { useState, useEffect } from "react";
import { bridge, type ScheduleInfo } from "../../sdk/bridge.js";

export function ScheduleList({
  onEdit,
}: {
  onEdit: (schedule: ScheduleInfo | null) => void;
}) {
  const [schedules, setSchedules] = useState<ScheduleInfo[]>([]);
  const [pendingDelete, setPendingDelete] = useState<string | null>(null);

  const refresh = () => {
    bridge.listSchedules().then(setSchedules).catch(() => {});
  };

  useEffect(() => {
    refresh();
    const unsub = bridge.onScheduleExecuted(() => refresh());
    return unsub;
  }, []);

  const handleToggle = (id: string, enabled: boolean) => {
    bridge.toggleSchedule(id, enabled).then(refresh);
  };

  const handleDelete = (id: string) => {
    bridge.deleteSchedule(id).then(() => {
      setPendingDelete(null);
      refresh();
    });
  };

  const handleTest = (id: string) => {
    bridge.testSchedule(id).catch(() => {});
  };

  return (
    <section data-role="schedule-list">
      <h4>Schedules</h4>
      <button onClick={() => onEdit(null)}>+ New Schedule</button>

      {schedules.length === 0 ? (
        <p data-role="empty">No schedules configured.</p>
      ) : (
        <ul>
          {schedules.map((s) => (
            <li key={s.id} data-enabled={s.enabled || undefined}>
              <label>
                <input
                  type="checkbox"
                  checked={s.enabled}
                  onChange={(e) => handleToggle(s.id, e.target.checked)}
                />
                <strong>{s.name}</strong>
              </label>
              <small>{describeRecurrence(s.recurrence)}</small>
              {s.lastRunAt && (
                <small>Last: {new Date(s.lastRunAt).toLocaleString()}</small>
              )}
              <span data-role="schedule-actions">
                <button onClick={() => onEdit(s)}>Edit</button>
                <button onClick={() => handleTest(s.id)}>Test</button>
                <button onClick={() => setPendingDelete(s.id)}>✕</button>
              </span>
            </li>
          ))}
        </ul>
      )}

      {pendingDelete && (
        <dialog open>
          <p>Delete this schedule?</p>
          <menu>
            <button onClick={() => handleDelete(pendingDelete)}>Delete</button>
            <button onClick={() => setPendingDelete(null)}>Cancel</button>
          </menu>
        </dialog>
      )}
    </section>
  );
}

function describeRecurrence(r: { type: string; [key: string]: unknown }): string {
  switch (r.type) {
    case "once": return `Once at ${r.at}`;
    case "interval": return `Every ${r.every} ${r.unit}`;
    case "daily": return `Daily at ${r.at}`;
    case "weekly": return `Weekly on ${r.day} at ${r.at}`;
    case "cron": return `Cron: ${r.expression}`;
    default: return r.type;
  }
}
