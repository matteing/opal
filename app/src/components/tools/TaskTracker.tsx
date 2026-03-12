/**
 * Task tracker visualization for the `tasks` tool output.
 * Renders a simple DAG view with status icons and dependency lines.
 */
export function TaskTracker({ output }: { output: string }) {
  // Parse tasks from the tool output (JSON or plain text)
  let tasks: TaskItem[];
  try {
    const parsed = JSON.parse(output);
    tasks = Array.isArray(parsed) ? parsed : parsed.tasks ?? [];
  } catch {
    // Not JSON — render as plain text
    return <pre>{output}</pre>;
  }

  if (tasks.length === 0) return <p>No tasks.</p>;

  const doneCount = tasks.filter((t) => t.status === "done").length;

  return (
    <div data-role="task-tracker">
      <ul>
        {tasks.map((task) => (
          <li key={task.id} data-task-status={task.status}>
            <span data-role="task-icon">{statusIcon(task.status)}</span>
            <span data-role="task-label">{task.label ?? task.id}</span>
            {task.status !== "done" && task.status !== "open" && (
              <small>({task.status})</small>
            )}
            {task.blocked_by && task.blocked_by.length > 0 && (
              <span data-role="task-deps">
                → depends on: {task.blocked_by.join(", ")}
              </span>
            )}
          </li>
        ))}
      </ul>
      <p data-role="task-progress">
        {doneCount}/{tasks.length} complete
      </p>
    </div>
  );
}

function statusIcon(status: string): string {
  switch (status) {
    case "done": return "✓";
    case "in_progress": return "●";
    case "blocked": return "✗";
    default: return "○";
  }
}

interface TaskItem {
  id: string;
  label?: string;
  status: string;
  blocked_by?: string[];
  [key: string]: unknown;
}
