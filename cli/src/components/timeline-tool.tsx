import React, { type FC } from "react";
import { Box, Text, useStdout } from "ink";
import { TaskList, Task as InkTask } from "ink-task-list";
import type { ToolCall } from "../state/types.js";
import {
  outputToText,
  parseStructuredTasksOutput,
  parseTasksOutput,
  parseTaskNotes,
  type ParsedTask,
} from "../lib/parsers.js";
import { colors } from "../lib/palette.js";
import { DiffBlock, type DiffPayload } from "./diff-block.js";

// ── Style by status ──────────────────────────────────────────────

const STATUS_STYLE: Record<ToolCall["status"], { icon: string; color: string }> = {
  running: { icon: "◐", color: colors.warning },
  done: { icon: "●", color: colors.success },
  error: { icon: "✕", color: colors.error },
};

// ── Props ────────────────────────────────────────────────────────

interface Props {
  tool: ToolCall;
  showOutput?: boolean;
  /** Sub-agent metadata, when this tool is a sub_agent invocation. */
  subAgent?: { model: string; toolCount: number };
}

/** A single tool invocation — icon, name, meta, optional output. */
export const TimelineTool: FC<Props> = ({ tool, showOutput = false, subAgent }) => {
  const { stdout } = useStdout();
  const maxLineWidth = (stdout?.columns ?? 80) - 6;

  const { icon, color } = STATUS_STYLE[tool.status];
  const outputText = tool.result?.output !== undefined ? outputToText(tool.result.output) : "";
  const taskData = parseTaskData(tool);
  const diff = parseDiffData(tool);

  return (
    <Box flexDirection="column" marginBottom={1}>
      <Text>
        <Text color={color}>{icon}</Text> <Text bold>{tool.meta}</Text>{" "}
        <Text dimColor>{tool.tool}</Text>
      </Text>

      {subAgent && (
        <Box marginLeft={2}>
          <Text dimColor>
            ⬢ {subAgent.model || "unknown"} · {subAgent.toolCount} tool
            {subAgent.toolCount !== 1 ? "s" : ""}
          </Text>
        </Box>
      )}

      {diff ? (
        <DiffBlock diff={diff} maxWidth={maxLineWidth} />
      ) : taskData ? (
        <TasksBlock
          tasks={taskData.tasks}
          summary={taskData.summary}
          notes={taskData.notes}
          maxWidth={maxLineWidth}
        />
      ) : (
        <ToolOutput
          tool={tool}
          outputText={outputText}
          showOutput={showOutput}
          maxWidth={maxLineWidth}
        />
      )}
    </Box>
  );
};

// ── Helpers ──────────────────────────────────────────────────────

interface TaskData {
  tasks: ParsedTask[];
  notes: string[];
  summary?: string;
}

/** Parse completed `tasks` tool output into structured task data. */
function parseTaskData(tool: ToolCall): TaskData | null {
  if (tool.tool !== "tasks" || tool.status !== "done" || tool.result?.ok !== true) return null;

  const structured = parseStructuredTasksOutput(tool.result.output);
  if (structured) return structured;

  if (typeof tool.result.output !== "string") return null;
  const raw = tool.result.output;
  const tasks = parseTasksOutput(raw);
  return tasks ? { tasks, notes: parseTaskNotes(raw) } : null;
}

/** Extract diff data from a completed write_file/edit_file tool result. */
function parseDiffData(tool: ToolCall): DiffPayload | null {
  if (tool.status !== "done" || tool.result?.ok !== true) return null;
  const meta = tool.result as Record<string, unknown>;
  const diff = (meta.meta as Record<string, unknown> | undefined)?.diff as DiffPayload | undefined;
  if (!diff?.hunks || !Array.isArray(diff.hunks)) return null;
  return diff;
}

function truncateOutput(output: string, maxLines: number, maxWidth: number): string {
  return output
    .split(/\r?\n/)
    .slice(-maxLines)
    .map((l) => l.slice(0, maxWidth))
    .join("\n");
}

/** Resolve the display content and color for a tool's output panel. */
function resolveContent(
  tool: ToolCall,
  outputText: string,
  showOutput: boolean,
): { text: string; color?: string } | null {
  if (tool.status === "running" && tool.streamOutput) return { text: String(tool.streamOutput) };
  if (tool.result && !tool.result.ok && tool.result.error)
    return { text: tool.result.error, color: colors.error };
  if (showOutput && tool.status !== "running" && outputText) return { text: outputText };
  return null;
}

// ── Sub-components ───────────────────────────────────────────────

const TASK_SPINNER = {
  interval: 140,
  frames: ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"],
};

const INK_STATUS: Record<string, "success" | "pending" | "loading" | "warning" | "error"> = {
  done: "success",
  open: "pending",
  in_progress: "loading",
  blocked: "error",
};

interface TasksBlockProps {
  tasks: ParsedTask[];
  summary?: string;
  notes: string[];
  maxWidth: number;
}

const TasksBlock: FC<TasksBlockProps> = ({ tasks, summary, notes, maxWidth }) => (
  <Box marginLeft={2} flexDirection="column">
    {tasks.length > 0 ? (
      <TaskList>
        {tasks.map((t) => (
          <InkTask
            key={t.id}
            label={t.label || t.id}
            state={INK_STATUS[t.status] ?? "pending"}
            spinner={TASK_SPINNER}
            status={[t.priority, t.group].filter(Boolean).join(" · ") || undefined}
          />
        ))}
      </TaskList>
    ) : (
      <Text dimColor>No tasks.</Text>
    )}
    {summary && <Text dimColor>{summary}</Text>}
    {notes.length > 0 && (
      <Text dimColor wrap="truncate-end">
        {truncateOutput(notes.join("\n"), 4, maxWidth)}
      </Text>
    )}
  </Box>
);

interface ToolOutputProps {
  tool: ToolCall;
  outputText: string;
  showOutput: boolean;
  maxWidth: number;
}

const ToolOutput: FC<ToolOutputProps> = ({ tool, outputText, showOutput, maxWidth }) => {
  const resolved = resolveContent(tool, outputText, showOutput);
  if (!resolved) return null;

  return (
    <Box marginLeft={1} borderStyle="single" borderColor={colors.border} paddingX={1}>
      <Text color={resolved.color} dimColor={!resolved.color} wrap="truncate-end">
        {truncateOutput(resolved.text, 15, maxWidth)}
      </Text>
    </Box>
  );
};
