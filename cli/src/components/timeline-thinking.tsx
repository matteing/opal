import React, { type FC } from "react";
import { Box, Text, useStdout } from "ink";
import { colors } from "../lib/palette.js";

interface Props {
  text: string;
}

/** A collapsed thinking block — dimmed italic text with a 💭 prefix. */
export const TimelineThinking: FC<Props> = ({ text }) => {
  const { stdout } = useStdout();
  const width = stdout?.columns ?? 80;

  if (!text) return null;

  const maxWidth = Math.min(width - 6, 120);
  const truncated = text
    .split(/\r?\n/)
    .slice(-8)
    .map((l) => l.slice(0, maxWidth))
    .join("\n");

  return (
    <Box flexDirection="column" marginBottom={1} marginLeft={2}>
      <Text dimColor italic color={colors.muted}>
        💭 {truncated}
      </Text>
    </Box>
  );
};
