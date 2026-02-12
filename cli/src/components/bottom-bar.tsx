import React, { useState, type FC } from "react";
import { Box, Text, useStdout } from "ink";
import TextInput from "ink-text-input";
import type { OpalActions, OpalState } from "../hooks/use-opal.js";

export interface BottomBarProps {
  state: OpalState;
  actions: OpalActions;
}

export const BottomBar: FC<BottomBarProps> = ({ state, actions }) => {
  const { stdout } = useStdout();
  const width = stdout?.columns ?? 80;
  const [value, setValue] = useState("");

  const placeholder = state.isRunning
    ? "Steer the response…"
    : "Send a message…";

  const handleSubmit = (text: string) => {
    if (!text.trim()) return;
    setValue("");

    if (text.trim().startsWith("/")) {
      actions.runCommand(text.trim());
      return;
    }

    if (state.isRunning) {
      actions.submitSteer(text.trim());
    } else {
      actions.submitPrompt(text.trim());
    }
  };

  const formatTokens = (tokens: number | undefined): string => {
    if (tokens == null) return '0';
    if (tokens >= 1000) {
      return Math.round(tokens / 1000) + 'k';
    }
    return tokens.toString();
  };

  const tokenDisplay = state.tokenUsage && state.tokenUsage.contextWindow > 0
    ? {
        used: formatTokens(state.tokenUsage.currentContextTokens),
        max: formatTokens(state.tokenUsage.contextWindow),
        pct: Math.min(100, Math.round((state.tokenUsage.currentContextTokens / state.tokenUsage.contextWindow) * 100))
      }
    : null;
  const ctxColor = tokenDisplay ? (tokenDisplay.pct >= 80 ? "red" : tokenDisplay.pct >= 60 ? "yellow" : "green") : undefined;

  return (
    <Box flexDirection="column">
      <Text dimColor>{"─".repeat(width)}</Text>
      <Box paddingX={1}>
        <Text color="magenta" bold>
          ❯{" "}
        </Text>
        <TextInput
          value={value}
          onChange={setValue}
          placeholder={placeholder}
          onSubmit={handleSubmit}
        />
      </Box>
      <Text> </Text>
      <Box paddingX={1} justifyContent="space-between">
        <Box gap={1}>
          <Text dimColor>
            <Text color="magenta" bold>
              /
            </Text>
            help
          </Text>
          <Text dimColor>│</Text>
          <Text dimColor>
            <Text bold>ctrl+c</Text> exit
          </Text>
          <Text dimColor>│</Text>
          <Text dimColor>
            <Text bold>ctrl+o</Text> tool output
          </Text>
        </Box>
        <Box gap={0}>
          {state.currentModel && (
            <Text dimColor>{state.currentModel}</Text>
          )}
          {state.currentModel && tokenDisplay && (
            <Text dimColor> · </Text>
          )}
          {tokenDisplay && (
            <Text color={ctxColor}>{tokenDisplay.used}/{tokenDisplay.max}</Text>
          )}
        </Box>
      </Box>
    </Box>
  );
};
