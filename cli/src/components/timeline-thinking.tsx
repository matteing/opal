import React, { type FC } from "react";
import { Box, Text } from "ink";
import { colors } from "../lib/palette.js";

interface Props {
  text: string;
}

/** A collapsed thinking block — dimmed italic text with a 💭 prefix. */
export const TimelineThinking: FC<Props> = ({ text }) => {
  if (!text) return null;

  return (
    <Box flexDirection="column" marginBottom={1} marginLeft={1}>
      <Text dimColor italic color={colors.muted} wrap="wrap">
        {text}
      </Text>
    </Box>
  );
};
