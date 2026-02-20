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

// ── Icons & colors by status ─────────────────────────────────────

const STATUS_ICON: Record<ToolCall["status"], string> = {
  running: "◐",
  done: "●",
  error: "✕",
};

const STATUS_COLOR: Record<ToolCall["status"], string> = {
  running: colors.warning,
  done: colors.success,
  error: colors.error,
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
  const width = stdout?.columns ?? 80;
  const maxOutput = width - 6;

  const icon = STATUS_ICON[tool.status];
  const color = STATUS_COLOR[tool.status];

  // Special rendering for the `tasks` tool
  const isTasksOutput = tool.tool === "tasks" && tool.status === "done" && tool.result?.ok;
  const outputText = tool.result?.output !== undefined ? outputToText(tool.result.output) : "";
  const structured = isTasksOutput ? parseStructuredTasksOutput(tool.result?.output) : null;
  const parsedTasks =
    structured?.tasks ??
    (isTasksOutput && typeof tool.result?.output === "string"
      ? parseTasksOutput(tool.result.output)
      : null);
  const taskNotes =
    structured?.notes ??
    (isTasksOutput && typeof tool.result?.output === "string"
      ? parseTaskNotes(tool.result.output)
      : []);

  return (
    <Box flexDirection="column" marginBottom={1}>
      <Text>
        <Text color={color}>{icon}</Text> <Text bold>{tool.meta}</Text>{" "}
        <Text dimColor>{tool.tool}</Text>
      </Text>

      {subAgent && (
        <Box marginLeft={2}>
          <Text dimColor>
            ⬢ {subAgent.model || "unknown"} · {subAgent.toolCount} tool{subAgent.toolCount !== 1 ? "s" : ""}
          </Text>
        </Box>
      )}

      {parsedTasks ? (
        <TasksBlock
          tasks={parsedTasks}
          summary={structured?.summary}
          notes={taskNotes}
          maxWidth={maxOutput}
        />
      ) : (
        <ToolOutput
          tool={tool}
          outputText={outputText}
          isTasksOutput={isTasksOutput ?? false}
          showOutput={showOutput}
          maxWidth={maxOutput}
        />
      )}
    </Box>
  );
};

// ── Helpers ──────────────────────────────────────────────────────

function truncateOutput(output: string, maxLines: number, maxWidth: number): string {
  return output
    .split(/\r?\n/)
    .slice(-maxLines)
    .map((l) => l.slice(0, maxWidth))
    .join("\n");
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

const TasksBlock: FC<{
  tasks: ParsedTask[];
  summary?: string;
  notes: string[];
  maxWidth: number;
}> = ({ tasks, summary, notes, maxWidth }) => (
  <>
    {tasks.length > 0 ? (
      <Box marginLeft={2}>
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
      </Box>
    ) : (
      <Box marginLeft={2}>
        <Text dimColor>No tasks.</Text>
      </Box>
    )}
    {summary && (
      <Box marginLeft={2}>
        <Text dimColor>{summary}</Text>
      </Box>
    )}
    {notes.length > 0 && (
      <Box marginLeft={2}>
        <Text dimColor wrap="truncate-end">
          {truncateOutput(notes.join("\n"), 4, maxWidth)}
        </Text>
      </Box>
    )}
  </>
);

const ToolOutput: FC<{
  tool: ToolCall;
  outputText: string;
  isTasksOutput: boolean;
  showOutput: boolean;
  maxWidth: number;
}> = ({ tool, outputText, isTasksOutput, showOutput = true, maxWidth }) => {
  // Determine what to display and with what color
  let content: string | null = null;
  let textColor: string | undefined;

  if (tool.status === "running" && tool.streamOutput) {
    content = String(tool.streamOutput);
  } else if (isTasksOutput && outputText) {
    content = outputText;
  } else if (!isTasksOutput && tool.result && !tool.result.ok && tool.result.error) {
    content = tool.result.error;
    textColor = colors.error;
  } else if (!isTasksOutput && showOutput && tool.status !== "running" && outputText) {
    content = outputText;
  }

  if (!content) return null;

  return (
    <Box marginLeft={1} borderStyle="single" borderColor={colors.border} padding={1}>
      <Text color={textColor} dimColor={!textColor} wrap="truncate-end">
        {truncateOutput(content, 15, maxWidth)}
      </Text>
    </Box>
  );
};
