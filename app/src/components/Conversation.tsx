import { useRef, useEffect } from "react";
import type { TimelineEntry } from "../state/types.js";

function UserMessage({ text }: { text: string }) {
  return (
    <section data-role="user">
      <strong>You</strong>
      <p>{text}</p>
    </section>
  );
}

function AssistantMessage({ text, isStreaming }: { text: string; isStreaming: boolean }) {
  return (
    <section data-role="assistant">
      <strong>✦ Opal {isStreaming && <small>(streaming…)</small>}</strong>
      <pre>{text || (isStreaming ? "" : "(empty response)")}</pre>
    </section>
  );
}

function ToolExecution({
  name,
  args,
  output,
  status,
}: {
  name: string;
  args: string;
  output: string | null;
  status: "running" | "done" | "error";
}) {
  const icon = status === "running" ? "⏳" : status === "done" ? "✓" : "✗";
  let argsSummary = args;
  try {
    const parsed = JSON.parse(args);
    argsSummary = Object.entries(parsed)
      .map(([k, v]) => `${k}: ${typeof v === "string" ? v : JSON.stringify(v)}`)
      .join(", ");
    if (argsSummary.length > 80) argsSummary = argsSummary.slice(0, 77) + "…";
  } catch {
    // keep as-is
  }

  return (
    <details data-status={status}>
      <summary>
        {icon} <strong>{name}</strong> <small>{argsSummary}</small>
      </summary>
      {output && <pre>{output}</pre>}
    </details>
  );
}

function ContextBadge({ label }: { label: string }) {
  return <p data-role="context">● Loaded {label}</p>;
}

function SkillBadge({ name }: { name: string }) {
  return <p data-role="skill">● Loaded skill: {name}</p>;
}

function StatusEntry({ message }: { message: string }) {
  return <p data-role="status">{message}</p>;
}

function ErrorEntry({ message }: { message: string }) {
  return <p data-role="error">⚠ {message}</p>;
}

function renderEntry(entry: TimelineEntry, index: number) {
  switch (entry.type) {
    case "user":
      return <UserMessage key={index} text={entry.text} />;
    case "assistant":
      return (
        <AssistantMessage key={index} text={entry.text} isStreaming={entry.isStreaming} />
      );
    case "tool":
      return (
        <ToolExecution
          key={index}
          name={entry.name}
          args={entry.args}
          output={entry.output}
          status={entry.status}
        />
      );
    case "context":
      return <ContextBadge key={index} label={entry.label} />;
    case "skill":
      return <SkillBadge key={index} name={entry.name} />;
    case "status":
      return <StatusEntry key={index} message={entry.message} />;
    case "error":
      return <ErrorEntry key={index} message={entry.message} />;
    case "thinking":
      return null; // thinking shown separately
    default:
      return null;
  }
}

export function Conversation({
  timeline,
  isRunning,
}: {
  timeline: TimelineEntry[];
  isRunning: boolean;
}) {
  const bottomRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [timeline.length, isRunning]);

  return (
    <article role="log" aria-live="polite">
      {timeline.map(renderEntry)}
      <div ref={bottomRef} />
    </article>
  );
}
