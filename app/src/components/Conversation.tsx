import { useRef, useEffect } from "react";
import type { TimelineEntry } from "../state/types.js";
import { MarkdownRenderer } from "./tools/MarkdownRenderer.js";
import { FileViewer, DiffView, WriteFileView } from "./tools/FileTools.js";
import { ShellOutput } from "./tools/ShellOutput.js";
import { GrepResults } from "./tools/GrepResults.js";
import { TaskTracker } from "./tools/TaskTracker.js";
import { CopyButton } from "./tools/CopyButton.js";

// ── Message components ───────────────────────────────────────

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
      <MarkdownRenderer text={text} isStreaming={isStreaming} />
    </section>
  );
}

// ── Tool rendering ───────────────────────────────────────────
// Dispatch to a specialized renderer based on the tool name.
// Falls back to a generic collapsible pre block for unknown tools.

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
  // While running, show a minimal spinner line
  if (status === "running") {
    return (
      <p data-role="tool-running">
        ⏳ <strong>{name}</strong> <small>{argsSummary(args)}</small>
      </p>
    );
  }

  // Dispatch to specialized renderer for completed tools
  if (output !== null) {
    const filePath = extractFilePath(args);

    switch (name) {
      case "read_file":
        return <FileViewer name={filePath} output={output} />;

      case "edit_file":
        return <DiffView name={filePath} output={output} />;

      case "write_file":
        return <WriteFileView name={filePath} output={output} />;

      case "shell": {
        const cmd = extractShellCommand(args);
        return <ShellOutput command={cmd} output={output} />;
      }

      case "grep":
        return <GrepResults output={output} />;

      case "tasks":
        return <TaskTracker output={output} />;
    }
  }

  // Default: generic collapsible output
  const icon = status === "done" ? "✓" : "✗";
  return (
    <details data-status={status}>
      <summary>
        {icon} <strong>{name}</strong> <small>{argsSummary(args)}</small>
      </summary>
      {output && (
        <>
          <pre>{output}</pre>
          <div data-role="tool-footer">
            <CopyButton text={output} />
          </div>
        </>
      )}
    </details>
  );
}

// ── Helpers ──────────────────────────────────────────────────

/** Extract a short summary from JSON-encoded tool arguments. */
function argsSummary(args: string): string {
  try {
    const parsed = JSON.parse(args);
    const summary = Object.entries(parsed)
      .map(([k, v]) => `${k}: ${typeof v === "string" ? v : JSON.stringify(v)}`)
      .join(", ");
    return summary.length > 80 ? summary.slice(0, 77) + "…" : summary;
  } catch {
    return args.length > 80 ? args.slice(0, 77) + "…" : args;
  }
}

/** Extract the file path from tool args (JSON with a `path` or `file` key). */
function extractFilePath(args: string): string {
  try {
    const parsed = JSON.parse(args);
    return parsed.path ?? parsed.file ?? parsed.file_path ?? "unknown";
  } catch {
    return "unknown";
  }
}

/** Extract the command string from shell tool args. */
function extractShellCommand(args: string): string {
  try {
    const parsed = JSON.parse(args);
    return parsed.command ?? parsed.cmd ?? args;
  } catch {
    return args;
  }
}

// ── Badge components ─────────────────────────────────────────

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

// ── Entry renderer ───────────────────────────────────────────

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
      return null;
    default:
      return null;
  }
}

// ── Conversation ─────────────────────────────────────────────

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
