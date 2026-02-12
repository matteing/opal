import React, { type FC } from "react";
import { Box, Text } from "ink";
import type { Task } from "../hooks/use-opal.js";

export interface ToolStatusProps {
  tasks: Task[];
}

const ICONS: Record<Task["status"], string> = {
  running: "◐",
  done: "●",
  error: "✕",
};

const COLORS: Record<Task["status"], string> = {
  running: "yellow",
  done: "green",
  error: "red",
};

export const ToolStatus: FC<ToolStatusProps> = ({ tasks }) => {
  const active = tasks.filter((t) => t.status === "running");
  if (active.length === 0) return null;

  return (
    <Box flexDirection="column" paddingX={1}>
      {active.map((task) => (
        <Box key={task.callId}>
          <Text color={COLORS[task.status]}>{ICONS[task.status]} </Text>
          <Text bold>{task.tool}</Text>
          <Text dimColor> {task.meta}</Text>
        </Box>
      ))}
    </Box>
  );
};
