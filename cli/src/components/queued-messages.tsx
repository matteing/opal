/**
 * QueuedMessages — displays pending steered messages awaiting processing.
 *
 * Rendered above the input bar as a subtle stack of dimmed entries.
 * Each entry disappears when the server emits `messageApplied`.
 *
 * @module
 */

import React, { type FC } from "react";
import { Box, Text } from "ink";
import { colors } from "../lib/palette.js";

interface Props {
  messages: readonly string[];
}

/** A single queued message line. */
const QueuedEntry: FC<{ text: string }> = ({ text }) => (
  <Box paddingLeft={2}>
    <Text color={colors.muted}>{"\u25cb"} </Text>
    <Text color={colors.muted} dimColor>
      {text.length > 72 ? text.slice(0, 69) + "..." : text}
    </Text>
  </Box>
);

/** Stack of queued messages waiting for the agent to process. */
export const QueuedMessages: FC<Props> = ({ messages }) => {
  if (messages.length === 0) return null;

  return (
    <Box flexDirection="column">
      {messages.map((text, i) => (
        <QueuedEntry key={`${i}-${text.slice(0, 16)}`} text={text} />
      ))}
    </Box>
  );
};
