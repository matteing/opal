import React, { type FC } from "react";
import { Box, Text, useStdout } from "ink";
import { Marked } from "marked";
import { markedTerminal } from "marked-terminal";
import type {
  OpalState,
  Message,
  Task,
  Skill,
  Context,
  TimelineEntry,
} from "../hooks/use-opal.js";
import { Welcome } from "./welcome.js";

const md = new Marked(markedTerminal() as any);

function renderMarkdown(text: string): string {
  const result = md.parse(text);
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

  if (state.timeline.length === 0) {
    return <Welcome />;
  }

  return (
    <Box flexDirection="column" paddingX={1}>
      {state.timeline.map((entry, i) => {
        if (entry.kind === "message") {
          // Only show the "✦ opal" badge on the first assistant block in a run.
          // If a prior assistant message exists with only tool/skill/context entries
          // between, treat this as a continuation (suppress badge).
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
          return (
            <MessageBlock key={i} message={entry.message} width={width} showBadge={showBadge} />
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
          return <SkillBlock key={i} skill={entry.skill} width={width} />;
        }
        if (entry.kind === "context") {
          return <ContextBlock key={i} context={entry.context} width={width} />;
        }
        return null;
      })}
    </Box>
  );
};

const MessageBlock: FC<{ message: Message; width: number; showBadge?: boolean }> = ({
  message,
  width,
  showBadge = true,
}) => {
  const isUser = message.role === "user";
  const badge = isUser ? "❯ You" : "✦ opal";
  const color = isUser ? "cyan" : "magenta";

  return (
    <Box flexDirection="column" marginBottom={1}>
      {showBadge && (
        <Text bold color={color}>
          {badge}
        </Text>
      )}
      <Box marginLeft={2} width={Math.min(width - 4, 120)}>
        {isUser ? (
          <Text wrap="wrap">{message.content}</Text>
        ) : (
          <Text>{renderMarkdown(message.content || "")}</Text>
        )}
      </Box>
    </Box>
  );
};

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

  return (
    <Box flexDirection="column" marginLeft={2} marginBottom={1}>
      <Text>
        <Text color={color}>{icon}</Text> <Text bold>{task.tool}</Text>{" "}
        <Text dimColor>{task.meta}</Text>
      </Text>
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
    </Box>
  );
};

function truncateOutput(
  output: string,
  maxLines: number,
  maxWidth: number,
): string {
  const lines = output.split("\n").slice(-maxLines);
  return lines.map((l) => l.slice(0, maxWidth)).join("\n");
}

const SkillBlock: FC<{ skill: Skill; width: number }> = ({ skill }) => {
  return (
    <Box flexDirection="column" marginLeft={2} marginBottom={1}>
      <Text>
        <Text color="blue">✨</Text> <Text bold>skill loaded</Text>{" "}
        <Text dimColor>{skill.name}</Text>
      </Text>
      <Box marginLeft={2}>
        <Text dimColor wrap="wrap">
          {skill.description}
        </Text>
      </Box>
    </Box>
  );
};

const ContextBlock: FC<{ context: Context; width: number }> = ({ context, width }) => {
  const maxFileWidth = width - 6;

  return (
    <Box flexDirection="column" marginLeft={2} marginBottom={1}>
      <Text>
        <Text color="cyan">📋</Text> <Text bold>context discovered</Text>{" "}
        <Text dimColor>({context.files.length} file{context.files.length !== 1 ? 's' : ''})</Text>
      </Text>
      <Box marginLeft={2} flexDirection="column">
        {context.files.map((file, i) => (
          <Text key={i} dimColor wrap="truncate-end">
            {file.slice(0, maxFileWidth)}
          </Text>
        ))}
      </Box>
    </Box>
  );
};
