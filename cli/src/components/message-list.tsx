import React, { type FC, useRef, memo } from "react";
import { Box, Text, useStdout } from "ink";
import { Marked } from "marked";
import { markedTerminal } from "marked-terminal";
import { TaskList, Task as InkTask } from "ink-task-list";
import type {
  OpalState,
  Message,
  Task,
  Skill,
  Context,
  TimelineEntry,
} from "../hooks/use-opal.js";
import { Welcome } from "./welcome.js";

let _cachedWidth = 0;
let _cachedMd: Marked | null = null;

function getMd(width: number): Marked {
  if (_cachedMd && _cachedWidth === width) return _cachedMd;
  _cachedWidth = width;
  _cachedMd = new Marked(
    markedTerminal({ width, reflowText: true, tableOptions: {} }) as any,
  );
  return _cachedMd;
}

function renderMarkdown(text: string, width: number): string {
  const result = getMd(width).parse(text);
  return typeof result === "string" ? result.trimEnd() : text;
}

export interface MessageListProps {
  state: OpalState;
  showToolOutput?: boolean;
}

export const MessageList: FC<MessageListProps> = ({
  state,
  showToolOutput = false,
}) => {
  const { stdout } = useStdout();
  const width = stdout?.columns ?? 80;

  const hasMessages = state.timeline.some((e) => e.kind === "message");

  return (
    <Box flexDirection="column">
      <Welcome dimmed={hasMessages} />

      {!hasMessages && state.timeline.length > 0 && (
        <Box flexDirection="column" paddingX={1}>
          {state.timeline.map((entry, i) => {
            if (entry.kind === "context") {
              return <ContextLines key={i} context={entry.context} />;
            }
            return null;
          })}
        </Box>
      )}

      {hasMessages && (
        <Box flexDirection="column" paddingX={1}>
          {state.timeline.map((entry, i) => {
            if (entry.kind === "message") {
              let showBadge = true;
              if (entry.message.role === "assistant") {
                for (let j = i - 1; j >= 0; j--) {
                  const prev = state.timeline[j]!;
                  if (prev.kind === "message") {
                    if (prev.message.role === "assistant") showBadge = false;
                    break;
                  }
                }
              }
              // Determine if this is the actively-streaming message:
              // it's the last assistant message in the timeline while the agent is running
              let isStreaming = false;
              if (state.isRunning && entry.message.role === "assistant") {
                let isLast = true;
                for (let j = i + 1; j < state.timeline.length; j++) {
                  if (state.timeline[j]!.kind === "message" && (state.timeline[j] as any).message.role === "assistant") {
                    isLast = false;
                    break;
                  }
                }
                isStreaming = isLast;
              }
              return (
                <MessageBlock key={i} message={entry.message} width={width} showBadge={showBadge} isStreaming={isStreaming} />
              );
            }
            if (entry.kind === "tool") {
              return (
                <ToolBlock
                  key={entry.task.callId}
                  task={entry.task}
                  width={width}
                  showOutput={showToolOutput}
                />
              );
            }
            if (entry.kind === "skill") {
              return (
                <Box key={i}>
                  <Text>
                    <Text color="green">●</Text> <Text dimColor>Loaded skill: {entry.skill.name}</Text>
                  </Text>
                </Box>
              );
            }
            if (entry.kind === "context") {
              return <ContextLines key={i} context={entry.context} />;
            }
            return null;
          })}
        </Box>
      )}
    </Box>
  );
};

const MessageBlock: FC<{ message: Message; width: number; showBadge?: boolean; isStreaming?: boolean }> = memo(({
  message,
  width,
  showBadge = true,
  isStreaming = false,
}) => {
  const isUser = message.role === "user";
  const badge = isUser ? "❯ You" : "✦ opal";
  const color = isUser ? "cyan" : "magenta";

  const cacheRef = useRef({ content: "", rendered: "" });

  let rendered: string;
  if (isUser) {
    rendered = message.content;
  } else {
    const contentWidth = Math.min(width - 4, 120);
    const cached = cacheRef.current;
    // Re-parse if: content differs significantly (>80 chars since last parse) or is shorter (edit/new msg)
    const delta = message.content.length - cached.content.length;
    if (cached.content === message.content) {
      rendered = cached.rendered;
    } else if (isStreaming && delta > 0 && delta < 80) {
      // During streaming with small delta, return cached version (skip expensive re-parse)
      rendered = cached.rendered;
    } else {
      rendered = renderMarkdown(message.content || "", contentWidth);
      cacheRef.current = { content: message.content, rendered };
    }
  }

  return (
    <Box flexDirection="column" marginBottom={1}>
      {showBadge && (
        <Text bold color={color}>
          {badge}
        </Text>
      )}
      <Box marginLeft={2} width={Math.min(width - 4, 120)}>
        {isUser ? (
          <Text wrap="wrap">{rendered}</Text>
        ) : (
          <Text>{rendered}</Text>
        )}
      </Box>
    </Box>
  );
}, (prev, next) => {
  // Custom comparison: skip re-render if content/width/badge haven't changed
  return prev.message === next.message && prev.width === next.width && prev.showBadge === next.showBadge && prev.isStreaming === next.isStreaming;
});

const TOOL_ICONS: Record<Task["status"], string> = {
  running: "◐",
  done: "●",
  error: "✕",
};

const TOOL_COLORS: Record<Task["status"], string> = {
  running: "yellow",
  done: "green",
  error: "red",
};

const ToolBlock: FC<{ task: Task; width: number; showOutput?: boolean }> = ({
  task,
  width,
  showOutput = false,
}) => {
  const icon = TOOL_ICONS[task.status];
  const color = TOOL_COLORS[task.status];
  const maxOutput = width - 6;

  // Special rendering for tasks tool with list action
  const isTasksList = task.tool === "tasks" && task.status === "done" && task.result?.ok && task.result.output;
  const parsedTasks = isTasksList ? parseTasksOutput(task.result!.output!) : null;

  return (
    <Box flexDirection="column" marginBottom={1}>
      <Text>
        <Text color={color}>{icon}</Text> <Text bold>{task.tool}</Text>{" "}
        <Text dimColor>{task.meta}</Text>
      </Text>
      {parsedTasks && parsedTasks.length > 0 ? (
        <Box marginLeft={2}>
          <TasksDisplay tasks={parsedTasks} />
        </Box>
      ) : (
        <>
          {task.subTasks && task.subTasks.length > 0 && (
            <Box flexDirection="column">
              {task.subTasks.map((sub) => (
                <ToolBlock
                  key={sub.callId}
                  task={sub}
                  width={width - 2}
                  showOutput={showOutput}
                />
              ))}
            </Box>
          )}
          {task.result && !task.result.ok && task.result.error && (
            <Box marginLeft={2}>
              <Text color="red" wrap="truncate-end">
                {task.result.error.slice(0, maxOutput)}
              </Text>
            </Box>
          )}
          {showOutput && task.result?.output && (
            <Box marginLeft={2}>
              <Text dimColor wrap="truncate-end">
                {truncateOutput(task.result.output, 12, maxOutput)}
              </Text>
            </Box>
          )}
        </>
      )}
    </Box>
  );
};

function truncateOutput(
  output: string,
  maxLines: number,
  maxWidth: number,
): string {
  const lines = output.split(/\r?\n/).slice(-maxLines);
  return lines.map((l) => l.slice(0, maxWidth)).join("\n");
}

const ContextLines: FC<{ context: Context }> = ({ context }) => {
  const items: string[] = [];
  for (const f of context.files) items.push(f);
  for (const s of context.skills) items.push(`skill: ${s}`);
  for (const m of context.mcpServers) items.push(`mcp: ${m}`);

  return (
    <Box flexDirection="column" marginBottom={1}>
      {items.map((item, i) => (
        <Box key={i}>
          <Text>
            <Text color="green">●</Text> <Text dimColor>Loaded {item}</Text>
          </Text>
        </Box>
      ))}
    </Box>
  );
};

// --- Tasks tool special rendering ---

interface ParsedTask {
  id: string;
  label: string;
  status: string;
  priority: string;
  group: string;
}

const STATUS_MAP: Record<string, "success" | "pending" | "loading" | "warning" | "error"> = {
  done: "success",
  open: "pending",
  in_progress: "loading",
  blocked: "error",
};

function parseTasksOutput(output: string): ParsedTask[] | null {
  const lines = output.split(/\r?\n/).filter(Boolean);
  // Expected: header, separator (---), then data rows, then "N task(s)"
  if (lines.length < 3) return null;
  const dataLines = lines.slice(2).filter((l) => !l.match(/^\d+ task\(s\)$/));
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

const TASK_SPINNER = { interval: 140, frames: ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"] };

const TasksDisplay: FC<{ tasks: ParsedTask[] }> = ({ tasks }) => {
  return (
    <TaskList>
      {tasks.map((t) => {
        const state = STATUS_MAP[t.status] ?? "pending";
        const extra = [t.priority, t.group].filter(Boolean).join(" · ") || undefined;
        return (
          <InkTask
            key={t.id}
            label={t.label || t.id}
            state={state}
            spinner={TASK_SPINNER}
            status={extra}
          />
        );
      })}
    </TaskList>
  );
};
