import React, { useState, useCallback, useRef, memo, type FC } from "react";
import { Box, Text, useStdout } from "ink";
import { StableTextInput } from "./stable-text-input.js";
import type { OpalActions, OpalState } from "../hooks/use-opal.js";
import { formatTokens } from "../lib/formatting.js";
import { colors } from "../lib/palette.js";

export interface BottomBarProps {
  state: OpalState;
  actions: OpalActions;
}

/**
 * Memoised so that high-frequency streaming events (messageDelta, etc.) do NOT
 * cascade into re-renders.  Uses StableTextInput which keeps its `useInput`
 * handler reference-stable, so Ink never tears down the stdin listener.
 */
export const BottomBar: FC<BottomBarProps> = memo(
  ({ state, actions }) => {
    const { stdout } = useStdout();
    const width = stdout?.columns ?? 80;
    const [value, setValue] = useState("");

    const isRunning = state.main.isRunning;

    const placeholder = isRunning ? "Steer the response…" : "Send a message…";

    // Refs so handleSubmit never changes identity
    const isRunningRef = useRef(isRunning);
    isRunningRef.current = isRunning;
    const actionsRef = useRef(actions);
    actionsRef.current = actions;

    const handleSubmit = useCallback((text: string) => {
      if (!text.trim()) return;
      setValue("");

      if (text.trim().startsWith("/")) {
        actionsRef.current.runCommand(text.trim());
        return;
      }

      if (isRunningRef.current) {
        actionsRef.current.submitSteer(text.trim());
      } else {
        actionsRef.current.submitPrompt(text.trim());
      }
    }, []);

    // formatTokens imported from lib/formatting

    const tokenDisplay =
      state.tokenUsage && state.tokenUsage.contextWindow > 0
        ? {
            used: formatTokens(state.tokenUsage.currentContextTokens),
            max: formatTokens(state.tokenUsage.contextWindow),
            pct: Math.min(
              100,
              Math.round(
                (state.tokenUsage.currentContextTokens / state.tokenUsage.contextWindow) * 100,
              ),
            ),
          }
        : null;
    const ctxColor = tokenDisplay
      ? tokenDisplay.pct >= 80
        ? colors.error
        : tokenDisplay.pct >= 60
          ? colors.warning
          : colors.success
      : undefined;

    return (
      <Box flexDirection="column">
        <Text dimColor>{"─".repeat(width)}</Text>
        <Box paddingX={1}>
          <Text color={colors.accent} bold>
            ❯{" "}
          </Text>
          <StableTextInput
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
              <Text color={colors.accent} bold>
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
              <Text bold>ctrl+o</Text> tools
            </Text>
            <Text dimColor>│</Text>
            <Text dimColor>
              <Text bold>ctrl+y</Text> plan
            </Text>
          </Box>
          <Box gap={0}>
            {state.currentModel && <Text dimColor>{state.currentModel}</Text>}
            {state.currentModel && tokenDisplay && <Text dimColor> · </Text>}
            {tokenDisplay && (
              <Text color={ctxColor}>
                {tokenDisplay.used}/{tokenDisplay.max}
              </Text>
            )}
          </Box>
        </Box>
      </Box>
    );
  },
  (prev, next) =>
    prev.state.main.isRunning === next.state.main.isRunning &&
    prev.state.currentModel === next.state.currentModel &&
    prev.state.tokenUsage === next.state.tokenUsage,
);
