// Extracted from components/message-list.tsx for testability

export interface ParsedTask {
  id: string;
  label: string;
  status: string;
  priority: string;
  group: string;
}

export interface StructuredTasksOutput {
  tasks: ParsedTask[];
  notes: string[];
  summary: string;
}

export function outputToText(output: unknown): string {
  if (typeof output === "string") return output;
  if (output == null) return "";
  if (typeof output === "number" || typeof output === "boolean" || typeof output === "bigint") {
    return `${output}`;
  }

  try {
    return JSON.stringify(output, null, 2);
  } catch {
    return "[non-serializable output]";
  }
}

export function parseStructuredTasksOutput(output: unknown): StructuredTasksOutput | null {
  if (!output || typeof output !== "object" || Array.isArray(output)) return null;
  const payload = output as Record<string, unknown>;
  if (payload.kind !== "tasks") return null;
  if (!Array.isArray(payload.tasks)) return null;

  const tasks = payload.tasks
    .map((raw) => {
      if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
      const task = raw as Record<string, unknown>;

      const id = typeof task.id === "string" || typeof task.id === "number" ? `${task.id}` : "";
      const label = typeof task.label === "string" ? task.label : "";
      const status =
        typeof task.status === "string" ? task.status : task.done === true ? "done" : "open";
      const priority = typeof task.priority === "string" ? task.priority : "";
      const group = typeof task.groupName === "string" ? task.groupName : "";

      return { id, label, status, priority, group };
    })
    .filter((task): task is ParsedTask => task !== null);

  const notes = Array.isArray(payload.notes)
    ? payload.notes.filter((v): v is string => typeof v === "string")
    : [];

  if (Array.isArray(payload.operations)) {
    for (const op of payload.operations) {
      if (!op || typeof op !== "object" || Array.isArray(op)) continue;
      const operation = op as Record<string, unknown>;
      if (operation.ok === false && typeof operation.error === "string") {
        const action = typeof operation.action === "string" ? operation.action : "operation";
        notes.push(`${action}: ${operation.error}`);
      }
    }
  }

  const total = typeof payload.total === "number" ? payload.total : tasks.length;
  const counts =
    payload.counts && typeof payload.counts === "object" && !Array.isArray(payload.counts)
      ? (payload.counts as Record<string, unknown>)
      : null;
  const open = typeof counts?.open === "number" ? counts.open : 0;
  const inProgress = typeof counts?.inProgress === "number" ? counts.inProgress : 0;
  const done = typeof counts?.done === "number" ? counts.done : 0;
  const blocked = typeof counts?.blocked === "number" ? counts.blocked : 0;

  const action = typeof payload.action === "string" ? payload.action : "tasks";
  const summary = `${action}: ${total} total · ${open} open · ${inProgress} in progress · ${done} done · ${blocked} blocked`;

  return { tasks, notes, summary };
}

export function parseTasksOutput(output: string): ParsedTask[] | null {
  const lines = output.split(/\r?\n/);
  const headerIndex = lines.findIndex((line) => line.startsWith("id | "));
  if (headerIndex < 0 || headerIndex + 2 >= lines.length) return null;

  const dataLines: string[] = [];
  for (const line of lines.slice(headerIndex + 2)) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    if (/^\d+ task\(s\)$/.test(trimmed)) break;
    if (!trimmed.includes(" | ")) continue;
    dataLines.push(trimmed);
  }

  if (dataLines.length === 0) return null;

  return dataLines.map((line) => {
    const cols = line.split(" | ").map((c) => c.trim());
    return {
      id: cols[0] ?? "",
      label: cols[1] ?? "",
      status: cols[2] ?? "open",
      priority: cols[3] ?? "",
      group: cols[4] ?? "",
    };
  });
}

export function parseTaskNotes(output: string): string[] {
  return output
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => /^\[[+\-~]\]/.test(line));
}
