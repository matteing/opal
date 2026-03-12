import type { TimelineEntry } from "../../state/types.js";

/**
 * Sub-agent nested timeline. Renders a collapsible view of a sub-agent's
 * work (tools, messages) within the parent conversation.
 *
 * Sub-agent events arrive as `subAgentEvent` in the parent timeline. This
 * component renders those events recursively using the same entry renderer.
 */
export function SubAgentTimeline({
  prompt,
  events,
  status,
}: {
  prompt: string;
  events: TimelineEntry[];
  status: "running" | "done" | "error";
}) {
  const icon = status === "running" ? "⏳" : status === "done" ? "✓" : "✗";
  const toolCount = events.filter((e) => e.type === "tool").length;

  return (
    <details data-role="sub-agent" data-status={status}>
      <summary>
        {icon} <strong>sub_agent</strong>{" "}
        <small>{prompt.length > 60 ? prompt.slice(0, 57) + "…" : prompt}</small>
        {status === "done" && <small> · {toolCount} tool call{toolCount !== 1 ? "s" : ""}</small>}
      </summary>
      <div data-role="sub-agent-timeline">
        {events.map((entry, i) => (
          <SubAgentEntry key={i} entry={entry} />
        ))}
        {events.length === 0 && status === "running" && (
          <p data-role="status">Working…</p>
        )}
      </div>
    </details>
  );
}

/** Simplified entry renderer for sub-agent timelines. */
function SubAgentEntry({ entry }: { entry: TimelineEntry }) {
  switch (entry.type) {
    case "assistant":
      return entry.text ? (
        <p data-role="sub-agent-message">{entry.text}</p>
      ) : null;
    case "tool": {
      const icon = entry.status === "running" ? "⏳" : entry.status === "done" ? "●" : "✗";
      return (
        <p data-role="sub-agent-tool" data-status={entry.status}>
          {icon} {entry.name}{" "}
          <small>{entry.args.length > 60 ? entry.args.slice(0, 57) + "…" : entry.args}</small>
        </p>
      );
    }
    case "status":
      return <p data-role="status">{entry.message}</p>;
    default:
      return null;
  }
}
