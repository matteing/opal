import React, { type FC } from "react";
import { Box, Text, useStdout } from "ink";
import type { TokenUsage } from "../sdk/protocol.js";

export interface TokenBarProps {
  usage: TokenUsage | null;
}

export const TokenBar: FC<TokenBarProps> = ({ usage }) => {
  const { stdout } = useStdout();
  const width = stdout?.columns ?? 80;

  if (!usage || usage.contextWindow === 0) return null;

  const pct = Math.min(
    100,
    Math.round((usage.currentContextTokens / usage.contextWindow) * 100),
  );
  const barWidth = Math.max(10, width - 30);
  const filled = Math.round((pct / 100) * barWidth);
  const empty = barWidth - filled;

  const color = pct >= 80 ? "red" : pct >= 60 ? "yellow" : "green";

  return (
    <Box paddingX={1}>
      <Text color={color}>{"█".repeat(filled)}</Text>
      <Text dimColor>{"░".repeat(empty)}</Text>
      <Text dimColor>
        {" "}
        {pct}% until /compact
      </Text>
    </Box>
  );
};
