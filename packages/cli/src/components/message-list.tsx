import React, { type FC, useRef, useMemo, memo } from "react";
import { Box, Text, useStdout } from "ink";
import { Marked, type MarkedExtension } from "marked";
import { markedTerminal } from "marked-terminal";
import { TaskList, Task as InkTask } from "ink-task-list";
import type {
  AgentView,
  SubAgent,
  Message,
  Task,
  Context,
  TimelineEntry,
} from "../hooks/use-opal.js";
import { Welcome } from "./welcome.js";
import {
  outputToText,
  parseStructuredTasksOutput,
  parseTasksOutput,
  parseTaskNotes,
  type ParsedTask,
} from "../lib/parsers.js";

let _cachedWidth = 0;
let _cachedMd: Marked | null = null;
const MAX_RENDERED_ENTRIES = 400;

function getMd(width: number): Marked {
  if (_cachedMd && _cachedWidth === width) return _cachedMd;
  _cachedWidth = width;
  _cachedMd = new Marked(
    markedTerminal({ width, reflowText: true, tableOptions: {} }) as MarkedExtension,
  );
  return _cachedMd;
}

function renderMarkdown(text: string, width: number): string {
  const result = getMd(width).parse(text);
  return typeof result === "string" ? result.trimEnd() : text;
}

export interface MessageListProps {
  view: AgentView;
  subAgents: Record<string, SubAgent>;
  showToolOutput?: boolean;
  sessionReady?: boolean;
}

export const MessageList: FC<MessageListProps> = memo(
  ({ view, subAgents, showToolOutput = false, sessionReady: _sessionReady = true }) => {
    const { stdout } = useStdout();
    const width = stdout?.columns ?? 80;
    const timeline = view.timeline;
    const startIndex = Math.max(0, timeline.length - MAX_RENDERED_ENTRIES);
    const visibleTimeline = startIndex > 0 ? timeline.slice(startIndex) : timeline;
    const hiddenCount = startIndex;
    const subAgentByCallId = useMemo(
      () =>
        new Map<string, SubAgent>(Object.values(subAgents).map((sub) => [sub.parentCallId, sub])),
      [subAgents],
    );

    const hasMessages = timeline.some((e: TimelineEntry) => e.kind === "message");

    return (
      <Box flexDirection="column">
        <Welcome dimmed={hasMessages} />
        {hiddenCount > 0 && (
          <Box paddingX={1} marginBottom={1}>
            <Text dimColor>
              Showing last {MAX_RENDERED_ENTRIES} of {timeline.length} timeline entries (use
              /compact to trim history).
            </Text>
          </Box>
        )}

        {!hasMessages && visibleTimeline.length > 0 && (
          <Box flexDirection="column" paddingX={1}>
            {visibleTimeline.map((entry: TimelineEntry, i: number) => {
              const timelineIndex = startIndex + i;
              if (entry.kind === "context") {
                return <ContextLines key={timelineIndex} context={entry.context} />;
              }
              return null;
            })}
          </Box>
        )}

        {hasMessages && (
          <Box flexDirection="column" paddingX={1}>
            {(() => {
              let lastMessageRole: Message["role"] | null = null;
              return visibleTimeline.map((entry: TimelineEntry, i: number) => {
                const timelineIndex = startIndex + i;
                if (entry.kind === "message") {
                  const showBadge =
                    entry.message.role === "assistant" ? lastMessageRole !== "assistant" : true;
                  lastMessageRole = entry.message.role;
                  const isStreaming =
                    view.isRunning &&
                    entry.message.role === "assistant" &&
                    timelineIndex === timeline.length - 1;
                  return (
                    <MessageBlock
                      key={timelineIndex}
                      message={entry.message}
                      width={width}
                      showBadge={showBadge}
                      isStreaming={isStreaming}
                    />
                  );
                }
                if (entry.kind === "tool") {
                  // Sub-agent tool: show collapsed summary
                  const subAgent =
                    entry.task.tool === "sub_agent"
                      ? (subAgentByCallId.get(entry.task.callId) ?? null)
                      : null;
                  if (subAgent) {
                    return (
                      <SubAgentSummary
                        key={entry.task.callId}
                        task={entry.task}
                        subAgent={subAgent}
                      />
                    );
                  }
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
                    <Box key={timelineIndex}>
                      <Text>
                        <Text color="green">●</Text>{" "}
                        <Text dimColor>Loaded skill: {entry.skill.name}</Text>
                      </Text>
                    </Box>
                  );
                }
                if (entry.kind === "thinking" && showToolOutput) {
                  return (
                    <ThinkingBlock
                      key={`thinking-${timelineIndex}`}
                      text={entry.text}
                      width={width}
                    />
                  );
                }
                if (entry.kind === "context") {
                  return <ContextLines key={timelineIndex} context={entry.context} />;
                }
                return null;
              });
            })()}
          </Box>
        )}
      </Box>
    );
  },
  (prev, next) =>
    prev.view === next.view &&
    prev.subAgents === next.subAgents &&
    prev.showToolOutput === next.showToolOutput,
);

const MessageBlock: FC<{
  message: Message;
  width: number;
  showBadge?: boolean;
  isStreaming?: boolean;
}> = memo(
  ({ message, width, showBadge = true, isStreaming: _isStreaming = false }) => {
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
      if (cached.content === message.content) {
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
          {isUser ? <Text wrap="wrap">{rendered}</Text> : <Text>{rendered}</Text>}
        </Box>
      </Box>
    );
  },
  (prev, next) => {
    return (
      prev.message.content === next.message.content &&
      prev.message.role === next.message.role &&
      prev.width === next.width &&
      prev.showBadge === next.showBadge &&
      prev.isStreaming === next.isStreaming
    );
  },
);

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

  const isTasksOutput = task.tool === "tasks" && task.status === "done" && task.result?.ok;
  const outputText = task.result?.output !== undefined ? outputToText(task.result.output) : "";
  const structuredTasks = isTasksOutput ? parseStructuredTasksOutput(task.result?.output) : null;
  const parsedTasks =
    structuredTasks?.tasks ??
    (isTasksOutput && typeof task.result?.output === "string"
      ? parseTasksOutput(task.result.output)
      : null);
  const taskNotes =
    structuredTasks?.notes ??
    (isTasksOutput && typeof task.result?.output === "string"
      ? parseTaskNotes(task.result.output)
      : []);

  return (
    <Box flexDirection="column" marginBottom={1}>
      <Text>
        <Text color={color}>{icon}</Text> <Text bold>{task.tool}</Text>{" "}
        <Text dimColor>{task.meta}</Text>
      </Text>
      {parsedTasks ? (
        <>
          {parsedTasks.length > 0 ? (
            <Box marginLeft={2}>
              <TasksDisplay tasks={parsedTasks} />
            </Box>
          ) : (
            <Box marginLeft={2}>
              <Text dimColor>No tasks.</Text>
            </Box>
          )}
          {structuredTasks?.summary && (
            <Box marginLeft={2}>
              <Text dimColor>{structuredTasks.summary}</Text>
            </Box>
          )}
          {taskNotes.length > 0 && (
            <Box marginLeft={2}>
              <Text dimColor wrap="truncate-end">
                {truncateOutput(taskNotes.join("\n"), 4, maxOutput)}
              </Text>
            </Box>
          )}
        </>
      ) : (
        <>
          {isTasksOutput && outputText && (
            <Box marginLeft={2}>
              <Text dimColor wrap="truncate-end">
                {truncateOutput(outputText, 12, maxOutput)}
              </Text>
            </Box>
          )}
          {!isTasksOutput && task.result && !task.result.ok && task.result.error && (
            <Box marginLeft={2}>
              <Text color="red" wrap="truncate-end">
                {task.result.error.slice(0, maxOutput)}
              </Text>
            </Box>
          )}
          {!isTasksOutput && showOutput && outputText && (
            <Box marginLeft={2}>
              <Text dimColor wrap="truncate-end">
                {truncateOutput(outputText, 12, maxOutput)}
              </Text>
            </Box>
          )}
        </>
      )}
    </Box>
  );
};

function truncateOutput(output: string, maxLines: number, maxWidth: number): string {
  const lines = output.split(/\r?\n/).slice(-maxLines);
  return lines.map((l) => l.slice(0, maxWidth)).join("\n");
}

const ThinkingBlock: FC<{ text: string; width: number }> = ({ text, width }) => {
  if (!text) return null;
  const maxWidth = Math.min(width - 6, 120);
  const truncated = truncateOutput(text, 8, maxWidth);
  return (
    <Box flexDirection="column" marginBottom={1} marginLeft={2}>
      <Text dimColor italic color="gray">
        💭 {truncated}
      </Text>
    </Box>
  );
};

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

const STATUS_MAP: Record<string, "success" | "pending" | "loading" | "warning" | "error"> = {
  done: "success",
  open: "pending",
  in_progress: "loading",
  blocked: "error",
};

// parseStructuredTasksOutput, parseTasksOutput, parseTaskNotes imported from lib/parsers

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

// --- Sub-agent collapsed summary ---

const SubAgentSummary: FC<{ task: Task; subAgent: SubAgent }> = ({ task, subAgent }) => {
  const icon = subAgent.isRunning ? "◐" : TOOL_ICONS[task.status];
  const color = subAgent.isRunning ? "yellow" : TOOL_COLORS[task.status];
  const elapsed = Math.round(
    ((subAgent.isRunning ? Date.now() : Date.now()) - subAgent.startedAt) / 1000,
  );

  const details = [
    `${subAgent.toolCount} tool${subAgent.toolCount !== 1 ? "s" : ""}`,
    subAgent.model,
    subAgent.isRunning ? `${elapsed}s` : `done in ${elapsed}s`,
  ].join(" · ");

  return (
    <Box flexDirection="column" marginBottom={1}>
      <Text>
        <Text color={color}>{icon}</Text> <Text bold>sub-agent</Text>{" "}
        <Text dimColor>"{subAgent.label}"</Text>
      </Text>
      <Box marginLeft={2}>
        <Text dimColor>↳ {details}</Text>
      </Box>
    </Box>
  );
};
